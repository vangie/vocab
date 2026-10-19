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
    @Published var selection: Suggestion.ID?
    @Published private(set) var entries: [DictionaryEntry] = []
    @Published var selectedDictionary: String? = nil   // nil = 全部
    /// The word whose entries are showing.
    @Published private(set) var searchedTerm = ""
    @Published var toast: String?
    private var history: [String] = []
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
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { suggestions = []; selection = nil; entries = []; searchedTerm = ""; return }
        suggestTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            if Task.isCancelled { return }
            let dicts = DictionarySelection.enabled()
            let r = await Task.detached { Suggester.suggest(q, in: dicts) }.value
            if Task.isCancelled || q != self.query.trimmingCharacters(in: .whitespacesAndNewlines) { return }
            self.suggestions = r.all
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
            if record, self.history.last != self.searchedTerm { self.history.append(self.searchedTerm) }
        }
    }

    /// Search for a word as if typed (links, wordbook, popup).
    func search(_ term: String? = nil) {
        if let term { query = term }
        queryChanged()
        let t = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, history.last != t { history.append(t) }
    }

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
        guard history.count > 1 else { return }
        history.removeLast()
        let t = history.removeLast()
        search(t)
    }

    var canGoBack: Bool { history.count > 1 }

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
final class WordbookModel: ObservableObject {
    static let shared = WordbookModel()
    @Published private(set) var items: [WordItem] = []
    @Published private(set) var dueItems: [WordItem] = []
    let store: WordStore?

    init() {
        store = try? WordStore(url: WordStore.defaultURL())
        reload()
    }

    func reload() {
        items = (try? store?.all()) ?? []
        dueItems = (try? store?.due()) ?? []
    }

    func add(entry: DictionaryEntry, word: String, context: String?) {
        _ = try? store?.add(word: word, definition: entry.snippet, dictionary: entry.dictionary.name, context: context)
        reload()
    }

    func contains(_ word: String) -> Bool { (try? store?.find(word: word)) != nil }

    func delete(_ ids: Set<Int64>) {
        for id in ids { try? store?.delete(id: id) }
        reload()
    }

    func rate(_ item: WordItem, _ r: ReviewRating) {
        _ = try? store?.review(id: item.id, rating: r)
        reload()
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "生词本.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // UTF-8 BOM so Excel/Numbers detect Chinese correctly.
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(CSVExporter.csv(items).utf8)
        try? data.write(to: url)
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
            if !WordUnderCursor.isTrusted {
                WordUnderCursor.requestTrust()
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
        } else {
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
