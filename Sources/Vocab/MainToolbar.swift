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
    func attach(to w: NSWindow) {
        guard window !== w || w.toolbar?.identifier != "vocab.main" else { return }
        window = w
        let tb = NSToolbar(identifier: "vocab.main")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        tb.centeredItemIdentifiers = [modeID]
        w.toolbar = tb
        w.toolbarStyle = .unified
        w.titleVisibility = .hidden
        bind()
        refresh()
        VocabLog.log("toolbar attached")
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
        fontGroup?.subitems.forEach { $0.isEnabled = lookupMode }
        if let f = searchItem?.searchField {
            f.placeholderString = state.mode == .wordbook ? "搜索生词本" : "搜索"
            let want = state.mode == .wordbook ? state.wordFilter : lookup.query
            if f.stringValue != want, f.currentEditor() == nil || state.mode != .lookup { f.stringValue = want }
            if f.stringValue != want, f.currentEditor() == nil { f.stringValue = want }
        }
    }

    func focusSearch() {
        guard let f = searchItem?.searchField, let w = window else { return }
        searchItem?.beginSearchInteraction()
        w.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
    }

    // MARK: NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, navID, .flexibleSpace, modeID, fontID, searchID]
    }

    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, navID, .flexibleSpace, modeID, .flexibleSpace, fontID, searchID]
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
            g.isNavigational = true
            navGroup = g
            return g
        case modeID:
            let g = NSToolbarItemGroup(itemIdentifier: id, titles: Mode.allCases.map { $0 == .lookup ? "词典" : $0.rawValue },
                                       selectionMode: .selectOne, labels: ["词典", "生词本", "背单词"],
                                       target: self, action: #selector(mode(_:)))
            g.label = "模式"
            g.controlRepresentation = .expanded
            modeGroup = g
            return g
        case fontID:
            let g = NSToolbarItemGroup(itemIdentifier: id, titles: ["小", "大"], selectionMode: .momentary,
                                       labels: ["缩小文字", "放大文字"], target: self, action: #selector(font(_:)))
            g.label = "文字大小"
            g.controlRepresentation = .expanded
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
