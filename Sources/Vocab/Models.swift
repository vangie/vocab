import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VocabCore

/// Which dictionaries to search: the user's choice, else Dictionary.app's active list.
enum DictionarySelection {
    static let key = "enabledDictionaryIDs"

    /// Cached: DCSGetActiveDictionaries costs ~20 ms and this is read on every keystroke/render.
    nonisolated(unsafe) private static var cache: [DictionaryInfo]?
    private static let lock = NSLock()
    static func invalidate() { lock.lock(); cache = nil; lock.unlock() }

    static func enabled() -> [DictionaryInfo] {
        lock.lock(); defer { lock.unlock() }
        if let cache { return cache }
        let v = compute(); cache = v; return v
    }

    private static func compute() -> [DictionaryInfo] {
        let svc = DictionaryService.shared
        let active = svc.activeDictionaries() + [BaikeClient.dictionary]   // 百度百科 on by default
        let d = UserDefaults.standard
        guard var ids = d.array(forKey: key) as? [String] else { return active }
        // One-time: add 百度百科 (new source, enabled by default) to an existing saved selection.
        if !d.bool(forKey: "baikeIntroduced") {
            d.set(true, forKey: "baikeIntroduced")
            if !ids.contains(BaikeClient.id) { ids.append(BaikeClient.id); d.set(ids, forKey: key) }
        }
        let all = svc.availableDictionaries()
        ids = autoEnableNew(ids, available: all, defaults: d)
        var out = ids.compactMap { id in all.first { $0.id == id } }
        if out.isEmpty { out = active }
        return out
    }

    static let knownKey = "knownDictionaryIDs"

    /// Dictionaries the user installs (bundles under ~/Library) after the selection was saved get
    /// enabled once, on first sight. Apple's built-ins and ones the user later turns off stay as they are.
    static func autoEnableNew(_ ids: [String], available: [DictionaryInfo], defaults d: UserDefaults,
                              home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        let local = available.filter { !$0.isNetwork }.map(\.id)
        guard let known = d.array(forKey: knownKey) as? [String] else {
            d.set(local, forKey: knownKey); return ids   // first run: remember what's there, change nothing
        }
        var ids = ids
        let fresh = available.filter { info in
            !info.isNetwork && !known.contains(info.id) && !ids.contains(info.id)
                && (info.bundleURL?.resolvingSymlinksInPath().path.hasPrefix(home + "/") ?? false)
        }
        if !fresh.isEmpty {
            ids += fresh.map(\.id); d.set(ids, forKey: key)
            VocabLog.log("auto-enabled new dictionaries: \(fresh.map(\.id).joined(separator: ", "))")
        }
        let merged = Array(Set(known).union(local)).sorted()
        if merged != known.sorted() { d.set(merged, forKey: knownKey) }
        return ids
    }
}

@MainActor
final class LookupModel: ObservableObject {
    static let shared = LookupModel()

    /// Text in the search field.
    @Published var query = ""
    /// Sidebar rows for the current query.
    @Published private(set) var suggestions: [Suggestion] = []
    /// The query the current `suggestions` belong to.
    @Published private(set) var suggestionsQuery: String? = nil
    @Published var selection: Suggestion.ID?
    @Published private(set) var entries: [DictionaryEntry] = []
    @Published var selectedDictionary: String? = nil   // nil = 全部
    /// The word whose entries are showing.
    @Published private(set) var searchedTerm = ""
    @Published var toast: String?
    /// Back/forward stack of looked-up words.
    @Published private(set) var nav: [String] = []
    @Published private(set) var navIndex = -1
    /// Recent lookups for the sidebar (most recent first, persisted).
    @Published private(set) var history = LookupHistory.load()
    var recents: [String] { history.words }
    private var dwellTask: Task<Void, Never>?
    /// Text zoom for entries (小/大, ⌘- / ⌘+), persisted.
    @Published var zoom: Double = UserDefaults.standard.object(forKey: "pageZoom") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(zoom, forKey: "pageZoom") }
    }
    /// Set while back/forward or a recent click fills the search field, so typing logic doesn't re-run.
    var suppressQueryChange = false
    private var suggestTask: Task<Void, Never>?
    private var showTask: Task<Void, Never>?

    var dictionariesWithResults: [DictionaryInfo] {
        var seen = Set<String>(); var out: [DictionaryInfo] = []
        for e in entries where !seen.contains(e.dictionary.id) { seen.insert(e.dictionary.id); out.append(e.dictionary) }
        return out
    }

    var visibleEntries: [DictionaryEntry] {
        guard let sel = selectedDictionary else { return entries }
        return entries.filter { $0.dictionary.id == sel }
    }

    var hasSpelling: Bool { suggestions.contains { $0.kind == .spelling } }

    /// Called as the user types: debounce, then refresh the sidebar and show the top match.
    func queryChanged() {
        suggestTask?.cancel(); dwellTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop the previous query's list right away; the new one arrives after the debounce.
        if suggestionsQuery != q { suggestions = []; suggestionsQuery = nil }
        guard !q.isEmpty else {
            // Also stop an in-flight lookup, or it would repaint the old word under an empty field.
            showTask?.cancel(); cancelNet()
            suggestions = []; selection = nil; entries = []; searchedTerm = ""; return
        }
        suggestTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            let dicts = DictionarySelection.enabled()
            let r = await Task.detached { Suggester.suggest(q, in: dicts) }.value
            if Task.isCancelled || q != self.query.trimmingCharacters(in: .whitespacesAndNewlines) { return }
            self.suggestions = r.all
            self.suggestionsQuery = q
            if let first = r.all.first {
                self.selection = first.id
                self.show(first.word, record: false)
            } else {
                self.selection = nil
                self.show(q, record: false)
            }
            // A typed result that stays on screen > 1 s counts as a committed lookup.
            self.dwellTask = Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if Task.isCancelled || q != self.query.trimmingCharacters(in: .whitespacesAndNewlines) { return }
                if !self.searchedTerm.isEmpty { self.recordHistory(self.searchedTerm) }
            }
        }
    }

    /// Bumped when the enabled set / order / prefs change, so views reading DictionarySelection re-render.
    @Published private(set) var dictionariesVersion = 0

    /// Settings › 词典 changed (toggle, reorder, prefs) or a dictionary was installed: refresh the
    /// tab strip, the sidebar suggestions and the shown entry right away.
    func dictionariesChanged() {
        DictionarySelection.invalidate()
        entryCache.removeAll(); entryCacheOrder.removeAll()
        dictionariesVersion += 1
        if let sel = selectedDictionary, !DictionarySelection.enabled().contains(where: { $0.id == sel }) { selectedDictionary = nil }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let term = searchedTerm
        if !q.isEmpty, suggestionsQuery == q {
            // Re-run the suggestions but keep showing the word the user picked.
            suggestTask?.cancel()
            let dicts = DictionarySelection.enabled()
            suggestTask = Task {
                let r = await Task.detached { Suggester.suggest(q, in: dicts) }.value
                if Task.isCancelled { return }
                self.suggestions = r.all
                if let s = self.selection, !r.all.contains(where: { $0.id == s }) { self.selection = r.all.first?.id }
            }
        }
        if !term.isEmpty { show(term, record: false) }
    }

    /// Local (DCS) results per word, newest last; small LRU so back/forward and re-typing are instant.
    private var entryCache: [String: (word: String, entries: [DictionaryEntry])] = [:]
    private var entryCacheOrder: [String] = []
    /// Network sources (Wikipedia, 百度百科): results per "dictID|lang|term"; failures aren't cached.
    private var netCache: [String: DictionaryEntry?] = [:]
    private var netTasks: [Task<Void, Never>] = []
    /// Local entries of the word on screen, and the network entries shown with them (by dictionary id).
    private var localShown: [DictionaryEntry] = []
    private var netShown: [String: DictionaryEntry] = [:]
    /// Wikipedia language chosen with the in-page switcher; kept for this session.
    private(set) var wikiLanguage: String?

    private func netKey(_ d: DictionaryInfo, _ term: String) -> String {
        d.isWikipedia ? "\(d.id)|\(wikiLanguage ?? "")|\(term)" : "\(d.id)||\(term)"
    }

    private func cancelNet() { netTasks.forEach { $0.cancel() }; netTasks = [] }

    private func rebuildEntries() {
        let order = DictionarySelection.enabled().filter(\.isNetwork).map(\.id)
        entries = localShown + order.compactMap { netShown[$0] }
        if let sel = selectedDictionary, !entries.contains(where: { $0.dictionary.id == sel }) { selectedDictionary = nil }
    }

    /// Show the entries for a word without touching the search field.
    /// Local dictionaries come first (milliseconds); network sources are fetched separately and appended.
    func show(_ word: String, record: Bool = true) {
        showTask?.cancel(); cancelNet()
        let dicts = DictionarySelection.enabled()
        let net = dicts.filter(\.isNetwork)
        showTask = Task {
            let t0 = Date()
            let r: (word: String, entries: [DictionaryEntry])
            if let c = self.entryCache[word] { r = c } else {
                r = await Task.detached(priority: .userInitiated) { Suggester.lookupWithFallback(word, in: dicts) }.value
                if Task.isCancelled { return }
                self.entryCache[word] = r; self.entryCacheOrder.append(word)
                if self.entryCacheOrder.count > 50 { self.entryCache[self.entryCacheOrder.removeFirst()] = nil }
            }
            if Task.isCancelled { return }
            // The field was cleared meanwhile: never show an entry under an empty search field.
            if self.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
            VocabLog.log("lookup \(word): local \(r.entries.count) entries in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            let term = r.entries.isEmpty ? word : r.word
            self.localShown = r.entries
            self.netShown = [:]
            var missing: [DictionaryInfo] = []
            for d in net {
                if let cached = self.netCache[self.netKey(d, term)] { if let e = cached { self.netShown[d.id] = e } }
                else {
                    self.netShown[d.id] = WikipediaClient.statusEntry(d.isWikipedia ? "正在查询维基百科…" : "正在查询百度百科…", dictionary: d, term: term)
                    missing.append(d)
                }
            }
            self.searchedTerm = term
            self.rebuildEntries()
            if record { self.recordVisit(term) }
            for d in missing { self.fetchNetwork(term, d) }
        }
    }

    private func fetchNetwork(_ term: String, _ d: DictionaryInfo) {
        let key = netKey(d, term)
        let lang = wikiLanguage
        netTasks.append(Task {
            let t0 = Date()
            let e: DictionaryEntry?
            let failed: Bool
            if d.isWikipedia {
                let o = await WikipediaClient.fetch(term, preferred: lang)
                e = WikipediaClient.entry(o, dictionary: d, term: term)
                if case .failed = o { failed = true } else { failed = false }
            } else {
                let o = await BaikeClient.fetch(term)
                e = BaikeClient.entry(o, term: term)
                if case .failed = o { failed = true } else { failed = false }
            }
            VocabLog.log("\(d.shortName) \(term): \(failed ? "failed" : e == nil ? "not found" : "found") in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            if Task.isCancelled || self.searchedTerm != term { return }
            if !failed { self.netCache[key] = .some(e) }
            if d.isWikipedia && lang != self.wikiLanguage { return }   // the switcher moved on meanwhile
            self.netShown[d.id] = e
            self.rebuildEntries()
        })
    }

    /// One network source's entry for `term` (shared cache and Wikipedia language), for the quick-lookup popup.
    func networkEntry(_ d: DictionaryInfo, _ term: String) async -> DictionaryEntry? {
        let key = netKey(d, term)
        if let cached = netCache[key] { return cached }
        let e: DictionaryEntry?; let failed: Bool
        if d.isWikipedia {
            let o = await WikipediaClient.fetch(term, preferred: wikiLanguage)
            e = WikipediaClient.entry(o, dictionary: d, term: term)
            if case .failed = o { failed = true } else { failed = false }
        } else {
            let o = await BaikeClient.fetch(term)
            e = BaikeClient.entry(o, term: term)
            if case .failed = o { failed = true } else { failed = false }
        }
        if !failed { netCache[key] = .some(e) }
        return e
    }

    /// In-page Wikipedia language switcher.
    func setWikiLanguage(_ code: String) {
        guard WikipediaClient.languages().contains(code) else { return }
        wikiLanguage = code
        NotificationCenter.default.post(name: .vocabWikiLanguageChanged, object: nil)
        guard !searchedTerm.isEmpty, let d = DictionarySelection.enabled().first(where: \.isWikipedia) else { return }
        let term = searchedTerm
        if let cached = netCache[netKey(d, term)] { netShown[d.id] = cached; rebuildEntries(); return }
        fetchNetwork(term, d)
    }

    /// Settings › 词典 changed the Wikipedia languages: drop cached articles.
    func wikiLanguagesChanged() {
        netCache = netCache.filter { !$0.key.contains("wikipedia") }
        if let w = wikiLanguage, !WikipediaClient.languages().contains(w) { wikiLanguage = nil }
        if !searchedTerm.isEmpty { show(searchedTerm, record: false) }
    }

    func search(_ term: String? = nil) {
        if let term { query = term }
        queryChanged()
        let t = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { recordVisit(t) }
    }

    /// Open a word from history/recents: fill the field, show it, no suggestion churn.
    func open(_ word: String, record: Bool = true) {
        // Only suppress when the field actually changes, or the flag would swallow the next keystroke.
        if query != word { suppressQueryChange = true }
        query = word
        suggestions = []
        suggestionsQuery = nil
        selection = nil
        show(word, record: record)
    }

    func recordVisit(_ t: String) {
        guard !t.isEmpty else { return }
        if navIndex >= 0, navIndex < nav.count, nav[navIndex] == t { return }
        if navIndex < nav.count - 1 { nav.removeSubrange((navIndex + 1)...) }
        nav.append(t); navIndex = nav.count - 1
        recordHistory(t)
    }

    func recordHistory(_ t: String) { history.record(t); history.save() }
    func removeHistory(_ w: String) { history.remove(w); history.save() }
    func clearRecents() { history.clear(); history.save() }

    func select(_ id: Suggestion.ID?) {
        selection = id
        if let s = suggestions.first(where: { $0.id == id }) { show(s.word) }
    }

    /// Up/down in the search field.
    func moveSelection(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        let i = suggestions.firstIndex { $0.id == selection } ?? -1
        let n = min(max(0, i + delta), suggestions.count - 1)
        // Arrowing through suggestions is browsing, not a committed lookup: don't record.
        selection = suggestions[n].id
        show(suggestions[n].word, record: false)
    }

    /// Enter in the search field.
    func commit() {
        if let s = suggestions.first(where: { $0.id == selection }) { show(s.word) }
        else { show(query) }
    }

    func back() {
        guard canGoBack else { return }
        navIndex -= 1
        open(nav[navIndex], record: false)
    }

    func forward() {
        guard canGoForward else { return }
        navIndex += 1
        open(nav[navIndex], record: false)
    }

    var canGoBack: Bool { navIndex > 0 }
    var canGoForward: Bool { navIndex >= 0 && navIndex < nav.count - 1 }

    func zoomIn() { zoom = min(2.0, (zoom * 10 + 1).rounded() / 10) }
    func zoomOut() { zoom = max(0.7, (zoom * 10 - 1).rounded() / 10) }

    func addCurrentToWordbook() {
        let pool = visibleEntries.isEmpty ? entries : visibleEntries
        guard let e = pool.first else { return }
        WordbookModel.shared.add(entry: e, word: searchedTerm.isEmpty ? e.headword : searchedTerm, context: nil)
        flash("已加入生词本：\(e.headword)")
    }

    func flash(_ s: String) {
        toast = s
        Task { try? await Task.sleep(nanoseconds: 1_600_000_000); if toast == s { toast = nil } }
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()
    private let takeover = TrackpadTakeover()
    @Published var takeoverEnabled: Bool = UserDefaults.standard.bool(forKey: "takeoverEnabled")
    @Published var accessibilityTrusted = WordUnderCursor.isTrusted
    @Published var multitouchDevices = 0
    @Published var lastError: String?
    @Published var lastTap: Date?
    @Published var frames = 0
    private var statusTimer: Timer?

    /// Poll monitor status for the line in Settings › 通用.
    func startStatusUpdates() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                let s = SettingsModel.shared
                s.accessibilityTrusted = WordUnderCursor.isTrusted
                s.lastTap = ThreeFingerMonitor.shared.lastTap
                s.frames = ThreeFingerMonitor.shared.frameCount
                s.multitouchDevices = ThreeFingerMonitor.shared.deviceCount
            }
        }
    }

    func setTakeover(_ on: Bool) {
        if on {
            guard WordUnderCursor.isTrusted else {
                // Guide the user instead of the system prompt; the takeover starts once granted.
                AccessibilityOnboarding.shared.show { SettingsModel.shared.setTakeover(true) }
                return
            }
            let n = ThreeFingerMonitor.shared.start()
            guard n > 0 else {
                lastError = n < 0 ? "无法加载触控板框架（MultitouchSupport）" : "没有找到触控板"
                takeoverEnabled = false
                UserDefaults.standard.set(false, forKey: "takeoverEnabled")
                return
            }
            multitouchDevices = n
            ThreeFingerMonitor.shared.onTap = { LookupPanelController.shared.lookUpUnderCursor() }
            takeover.engage()
            ClickSuppressor.shared.start()
        } else {
            ClickSuppressor.shared.stop()
            ThreeFingerMonitor.shared.stop()
            multitouchDevices = 0
            takeover.restore()
        }
        lastError = nil
        takeoverEnabled = on
        UserDefaults.standard.set(on, forKey: "takeoverEnabled")
    }

    func applyOnLaunch() {
        VocabLog.log("launch: AXIsProcessTrusted=\(WordUnderCursor.isTrusted) takeoverEnabled=\(takeoverEnabled) bundle=\(Bundle.main.bundlePath)")
        // If we previously took over but the app did not exit cleanly, the saved originals remain.
        if takeoverEnabled { setTakeover(true) }
        else if takeover.isEngaged { takeover.restore() }
    }

    /// Give the gesture back to the system while Vocab is not running.
    func releaseOnQuit() {
        if takeoverEnabled {
            ThreeFingerMonitor.shared.stop()
            takeover.restore()
        }
    }

    func refreshTrust() { accessibilityTrusted = WordUnderCursor.isTrusted }
}
