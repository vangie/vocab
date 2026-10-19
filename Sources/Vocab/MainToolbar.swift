import AppKit
import Combine
import SwiftUI
import VocabCore

/// Which of the three peer functions the main window shows.
enum WordbookScope: String, CaseIterable, Identifiable {
    case all = "全部", due = "待复习", recent = "最近加入"
    var id: String { rawValue }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var mode: Mode = .lookup
    /// Search text used to filter the wordbook in 生词本 mode.
    @Published var wordFilter = ""
    @Published var wordScope: WordbookScope = .all
}

/// Real NSToolbar on the main window so AppKit handles layout and the » overflow:
/// [sidebar toggle] | ‹ › ……… 词典 · 生词本 · 背单词 ……… 小|大 [搜索]
@MainActor
final class MainToolbarController: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
    static let shared = MainToolbarController()

    private let navID = NSToolbarItem.Identifier("vocab.nav")
    private let modeID = NSToolbarItem.Identifier("vocab.mode")
    private let fontID = NSToolbarItem.Identifier("vocab.font")
    private let searchID = NSToolbarItem.Identifier("vocab.search")

    private weak var window: NSWindow?
    private var navGroup: NSToolbarItemGroup?
    private var modeGroup: NSToolbarItemGroup?
    private var fontGroup: NSToolbarItemGroup?
    private var searchItem: NSSearchToolbarItem?
    private var bag: Set<AnyCancellable> = []

    var lookup: LookupModel { LookupModel.shared }
    var state: AppState { AppState.shared }

    /// Install on the window hosting the main view (idempotent).
    /// Set once applicationDidFinishLaunching has returned. Before that, launch work (the trackpad
    /// takeover waits on `defaults` and spins the run loop) can run our queued attach re-entrantly,
    /// and installing the toolbar from inside it crashed in -[NSToolbar _loadAllPlaceholderItems].
    static var launchFinished = false

    func attach(to w: NSWindow) {
        guard Self.launchFinished else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { self.attach(to: w) } }
            return
        }
        guard window !== w || w.toolbar?.identifier != "vocab.main" else { return }
        window = w
        let tb = NSToolbar(identifier: "vocab.main")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        w.toolbar = tb
        w.toolbarStyle = .unified
        w.styleMask.insert(.fullSizeContentView)
        w.title = "生词"               // kept for the Window menu / Mission Control
        w.titleVisibility = .hidden    // the mode switcher takes the title's place
        bind()
        refresh()
        // Re-assert on key/reopen in case SwiftUI swaps the toolbar or resets the title.
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification, object: w)
            .sink { [weak self, weak w] _ in
                guard let self, let w else { return }
                if w.toolbar?.identifier != "vocab.main" || w.titleVisibility != .hidden {
                    VocabLog.log("toolbar reasserted (was \(w.toolbar?.identifier ?? "none"), title \(w.titleVisibility == .hidden ? "hidden" : "visible"))")
                    self.window = nil
                    self.attach(to: w)
                }
            }.store(in: &bag)
        VocabLog.log("toolbar attached: \(w.toolbar?.items.map(\.itemIdentifier.rawValue) ?? [])")
    }

    private func bind() {
        bag = []
        lookup.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &bag)
        state.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &bag)
        NotificationCenter.default.publisher(for: .vocabFocusSearch).sink { [weak self] _ in self?.focusSearch() }.store(in: &bag)
    }

    func refresh() {
        navGroup?.subitems[0].isEnabled = lookup.canGoBack
        navGroup?.subitems[1].isEnabled = lookup.canGoForward
        modeGroup?.selectedIndex = Mode.allCases.firstIndex(of: state.mode) ?? 0
        let lookupMode = state.mode == .lookup
        // ‹ › and 小|大 only do something in 词典: take them out of the toolbar elsewhere
        // (removing items keeps AppKit's layout and » overflow exact, and the AX tree honest).
        setPresent(fontID, lookupMode, before: searchID)
        setPresent(navID, lookupMode, before: lookupMode ? fontID : searchID)
        if let f = searchItem?.searchField {
            f.placeholderString = state.mode == .wordbook ? "搜索生词本" : "搜索"
            let want = state.mode == .wordbook ? state.wordFilter : lookup.query
            // Typing writes the model immediately, so a mismatch means a programmatic change
            // (history, recents, links, test hook): mirror it — unless an IME is composing.
            let composing = (f.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
            if f.stringValue != want, !composing { f.stringValue = want }
        }
    }

    private func setPresent(_ id: NSToolbarItem.Identifier, _ present: Bool,
                            after: NSToolbarItem.Identifier? = nil, before: NSToolbarItem.Identifier? = nil) {
        guard let tb = window?.toolbar else { return }
        let ids = tb.items.map(\.itemIdentifier)
        if let i = ids.firstIndex(of: id) {
            if !present { tb.removeItem(at: i) }
        } else if present {
            if let a = after, let j = ids.firstIndex(of: a) { tb.insertItem(withItemIdentifier: id, at: j + 1) }
            else if let b = before, let j = ids.firstIndex(of: b) { tb.insertItem(withItemIdentifier: id, at: j) }
        }
    }

    /// 小 / 大 drawn as template images at distinct sizes (11 pt / 15 pt), like Dictionary.app.
    static func glyph(_ s: String, size: CGFloat) -> NSImage {
        let font = NSFont.systemFont(ofSize: size, weight: .regular)
        let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.black])
        let sz = str.size()
        let img = NSImage(size: NSSize(width: ceil(sz.width), height: ceil(sz.height)), flipped: false) { r in
            str.draw(at: .zero); return true
        }
        img.isTemplate = true
        img.accessibilityDescription = s
        return img
    }

    func focusSearch() {
        guard let f = searchItem?.searchField, let w = window else { return }
        searchItem?.beginSearchInteraction()
        w.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
    }

    // MARK: NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, navID, .flexibleSpace, modeID, fontID, searchID]
    }

    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, modeID, .flexibleSpace, navID, fontID, searchID]
    }

    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        switch id {
        case navID:
            let g = NSToolbarItemGroup(itemIdentifier: id,
                                       images: [NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "后退")!,
                                                NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "前进")!],
                                       selectionMode: .momentary, labels: ["后退", "前进"],
                                       target: self, action: #selector(nav(_:)))
            g.label = "后退/前进"
            g.controlRepresentation = .expanded
            // Not isNavigational: AppKit pins navigational items to the leading edge, ahead of
            // the mode switcher, whatever the identifier order says.
            g.isNavigational = false
            g.autovalidates = false
            g.subitems.forEach { $0.autovalidates = false; $0.isEnabled = true }
            navGroup = g
            return g
        case modeID:
            let g = NSToolbarItemGroup(itemIdentifier: id, titles: Mode.allCases.map { $0 == .lookup ? "词典" : $0.rawValue },
                                       selectionMode: .selectOne, labels: ["词典", "生词本", "背单词"],
                                       target: self, action: #selector(mode(_:)))
            g.label = "模式"
            g.controlRepresentation = .expanded
            g.autovalidates = false
            g.subitems.forEach { $0.autovalidates = false; $0.isEnabled = true }
            modeGroup = g
            return g
        case fontID:
            let g = NSToolbarItemGroup(itemIdentifier: id,
                                       images: [Self.glyph("小", size: 11), Self.glyph("大", size: 15)],
                                       selectionMode: .momentary,
                                       labels: ["缩小文字", "放大文字"], target: self, action: #selector(font(_:)))
            g.label = "文字大小"
            g.controlRepresentation = .expanded
            g.autovalidates = false
            g.subitems.forEach { $0.autovalidates = false; $0.isEnabled = true }
            fontGroup = g
            return g
        case searchID:
            let s = NSSearchToolbarItem(itemIdentifier: id)
            s.searchField.placeholderString = "搜索"
            s.searchField.delegate = self
            s.searchField.sendsSearchStringImmediately = true
            s.preferredWidthForSearchField = 200
            s.resignsFirstResponderWithCancel = false
            s.label = "搜索"
            searchItem = s
            return s
        default:
            return NSToolbarItem(itemIdentifier: id)
        }
    }

    // MARK: actions

    @objc private func nav(_ g: NSToolbarItemGroup) {
        state.mode = .lookup
        if g.selectedIndex == 0 { lookup.back() } else { lookup.forward() }
    }

    @objc private func mode(_ g: NSToolbarItemGroup) {
        let i = g.selectedIndex
        if Mode.allCases.indices.contains(i) { state.mode = Mode.allCases[i] }
    }

    @objc private func font(_ g: NSToolbarItemGroup) {
        if g.selectedIndex == 0 { lookup.zoomOut() } else { lookup.zoomIn() }
    }

    // MARK: search field

    func controlTextDidChange(_ n: Notification) {
        guard let f = n.object as? NSSearchField else { return }
        // IME composition (pinyin marked text): wait for the committed text.
        if let tv = f.currentEditor() as? NSTextView, tv.hasMarkedText() { return }
        switch state.mode {
        case .wordbook: state.wordFilter = f.stringValue
        case .review: state.mode = .lookup; lookup.query = f.stringValue
        case .lookup: lookup.query = f.stringValue
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard state.mode == .lookup else { return false }
        switch sel {
        case #selector(NSResponder.moveDown(_:)): lookup.moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)): lookup.moveSelection(-1); return true
        case #selector(NSResponder.insertNewline(_:)): lookup.commit(); return true
        default: return false
        }
    }
}

/// Finds the hosting NSWindow and installs the AppKit toolbar on it.
struct WindowToolbarInstaller: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { MainToolbarController.shared.attach(to: w) } }
            // SwiftUI may install its own toolbar after us; re-assert once things settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { MainToolbarController.shared.attach(to: w) } }
        }
    }
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ v: NSView, context: Context) {}
}
