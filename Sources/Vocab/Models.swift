import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VocabCore

/// Which dictionaries to search: the user's choice, else Dictionary.app's active list.
enum DictionarySelection {
    static let key = "enabledDictionaryIDs"

    static func enabled() -> [DictionaryInfo] {
        let svc = DictionaryService.shared
        let active = svc.activeDictionaries()
        guard let ids = UserDefaults.standard.array(forKey: key) as? [String] else { return active }
        let all = svc.availableDictionaries()
        var out = ids.compactMap { id in all.first { $0.id == id } }
        if out.isEmpty { out = active }
        return out
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
    @Published private(set) var recents: [String] = UserDefaults.standard.stringArray(forKey: "recentLookups") ?? []
    private var recentList = RecentList(UserDefaults.standard.stringArray(forKey: "recentLookups") ?? [])
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
        suggestTask?.cancel()
        recentList.refresh(); recents = recentList.displayed
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop the previous query's list right away; the new one arrives after the debounce.
        if suggestionsQuery != q { suggestions = []; suggestionsQuery = nil }
        guard !q.isEmpty else { suggestions = []; selection = nil; entries = []; searchedTerm = ""; return }
        suggestTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
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
        }
    }

    /// Show the entries for a word without touching the search field.
    func show(_ word: String, record: Bool = true) {
        showTask?.cancel()
        let dicts = DictionarySelection.enabled()
        showTask = Task {
            let r = await Task.detached { Suggester.lookupWithFallback(word, in: dicts) }.value
            if Task.isCancelled { return }
            self.entries = r.entries
            self.searchedTerm = r.entries.isEmpty ? word : r.word
            if let sel = self.selectedDictionary, !r.entries.contains(where: { $0.dictionary.id == sel }) {
                self.selectedDictionary = nil
            }
            if record { self.recordVisit(self.searchedTerm) }
        }
    }

    /// Search for a word as if typed (links, wordbook, popup).
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
        // Stored now, displayed order stays frozen until the next typed query.
        recentList.record(t)
        UserDefaults.standard.set(recentList.stored, forKey: "recentLookups")
    }

    func clearRecents() { recentList.clear(); recents = []; UserDefaults.standard.removeObject(forKey: "recentLookups") }

    func select(_ id: Suggestion.ID?) {
        selection = id
        if let s = suggestions.first(where: { $0.id == id }) { show(s.word) }
    }

    /// Up/down in the search field.
    func moveSelection(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        let i = suggestions.firstIndex { $0.id == selection } ?? -1
        let n = min(max(0, i + delta), suggestions.count - 1)
        select(suggestions[n].id)
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
