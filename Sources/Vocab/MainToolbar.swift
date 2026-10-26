import AppKit
import Combine
import SwiftUI
import VocabCore

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var mode: Mode = .lookup
    /// Search text used to filter the wordbook in 生词本 mode.
    @Published var wordFilter = ""
    @Published var wordScope: WordbookScope = .all
    /// 词书 filter of the 记词 list.
    @Published var wordSource: WordSourceFilter = .all
    /// Sidebar grouping in 生词本 (wordbook, tag or source).
    @Published var wordGroup: WordGroup = .today
    /// Selected Settings tab ("general" / "dictionary" / "review").
    @Published var settingsTab = "general"
    /// Bumped to ask the main window to open Settings (SwiftUI's openSettings).
    @Published var settingsRequest = 0
    /// 背诵计划 lives in Settings › 背单词.
    func openPlan() { settingsTab = "review"; settingsRequest += 1 }
    /// Table scroll offset, kept while the user looks a word up and comes back.
    var wordTableScroll: CGFloat?
    var wordSortKey: String = UserDefaults.standard.string(forKey: "wordSortKey") ?? "added" {
        didSet { UserDefaults.standard.set(wordSortKey, forKey: "wordSortKey") }
    }
    var wordSortAscending: Bool = UserDefaults.standard.object(forKey: "wordSortAscending") as? Bool ?? false {
        didSet { UserDefaults.standard.set(wordSortAscending, forKey: "wordSortAscending") }
    }
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
    private let newBookID = NSToolbarItem.Identifier("vocab.newBook")
    private let studyID = NSToolbarItem.Identifier("vocab.plan")

    private weak var window: NSWindow?
    private var navGroup: NSToolbarItemGroup?
    private var modeControl: NSSegmentedControl?
    private var fontGroup: NSToolbarItemGroup?
    private var searchItem: NSSearchToolbarItem?
    private var bag: Set<AnyCancellable> = []
    /// The user put the caret in the search field on purpose (click or ⌘F); until it ends editing,
    /// typing goes to search even during a quiz.
    private var searchExplicit = false { didSet { if searchExplicit { searchExplicitAt = Date() } } }
    private var searchExplicitAt = Date.distantPast
    private var focusMonitors: [Any] = []

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
        installQuizFocus()
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
        // Lay out with the final safe area before revealing the window (see Probe).
        w.contentView?.layoutSubtreeIfNeeded()
        let first = w.contentLayoutRect
        DispatchQueue.main.async {
            w.displayIfNeeded()
            w.alphaValue = 1
            VocabLog.log("window shown: contentLayoutRect \(NSStringFromRect(first))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let later = w.contentLayoutRect
                VocabLog.log("window +1s: contentLayoutRect \(NSStringFromRect(later)) \(later == first ? "(stable)" : "(JUMPED)")")
            }
        }
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
        AppNav.shared.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &bag)
        AppNav.shared.start()
        NotificationCenter.default.publisher(for: .vocabFocusSearch).sink { [weak self] _ in self?.focusSearch() }.store(in: &bag)
    }

    private var lastMode: Mode?

    func refresh() {
        if state.mode != lastMode {
            let entering = state.mode == .lookup
            lastMode = state.mode
            if entering, lookup.query.trimmingCharacters(in: .whitespaces).isEmpty,
               !(window?.firstResponder is NSTextView) {
                DispatchQueue.main.async { [weak self] in self?.focusSearch() }
            }
        }
        navGroup?.subitems[0].isEnabled = AppNav.shared.canGoBack
        navGroup?.subitems[1].isEnabled = AppNav.shared.canGoForward
        modeControl?.selectedSegment = Mode.allCases.firstIndex(of: state.mode) ?? 0
        let lookupMode = state.mode == .lookup
        // 小|大 only does something in 词典: take them out of the toolbar elsewhere
        // (removing items keeps AppKit's layout and » overflow exact, and the AX tree honest).
        setPresent(fontID, lookupMode, before: searchID)
        setPresent(studyID, state.mode == .words, before: searchID)
        // ‹ › are global (history spans 词典 and 记词): always present, leftmost before the modes.
        setPresent(navID, true, before: modeID)
        if let f = searchItem?.searchField {
            f.placeholderString = state.mode == .words ? "搜索单词" : "搜索"
            let want = state.mode == .words ? state.wordFilter : lookup.query
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

    /// [flexible space][新建生词本] in the sidebar section (before the tracking separator), so the
    /// button sits at the sidebar's trailing edge like Notes' new-folder button.
    private func setPresentAtStart(_ id: NSToolbarItem.Identifier, _ present: Bool) {
        guard let tb = window?.toolbar else { return }
        if let i = tb.items.firstIndex(where: { $0.itemIdentifier == id }) {
            guard !present else { return }
            tb.removeItem(at: i)
            if i > 0, tb.items[i - 1].itemIdentifier == .flexibleSpace { tb.removeItem(at: i - 1) }
        } else if present {
            tb.insertItem(withItemIdentifier: id, at: 0)
            tb.insertItem(withItemIdentifier: .flexibleSpace, at: 0)
        }
    }

    /// 小 / 大 drawn as template images at distinct sizes (11 pt / 15 pt), like Dictionary.app.
    /// 小/大 like Dictionary.app: different glyph sizes on one fixed canvas (so the toolbar doesn't
    /// scale them to the same height), bold, template so the segmented control tints it at full label strength.
    static func glyph(_ s: String, size: CGFloat) -> NSImage {
        let canvas = NSSize(width: 13, height: 14)   // small canvas → narrow segments, like Dictionary.app
        let img = NSImage(size: canvas, flipped: false) { r in
            let str = NSAttributedString(string: s, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .bold),
                .foregroundColor: NSColor.black])   // template: the control tints it like its other symbols
            let sz = str.size()
            str.draw(at: NSPoint(x: (r.width - sz.width) / 2, y: (r.height - sz.height) / 2))
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = s
        return img
    }

    /// ⌘V lookup: the clipboard word goes into the search field (caret at end) and is shown at once.
    private func pasteLookup(_ t: String, _ f: NSSearchField) {
        focusSearch()
        f.stringValue = t
        f.currentEditor()?.selectedRange = NSRange(location: (t as NSString).length, length: 0)
        lookup.open(t)
    }

    func focusSearch() {
        guard let f = searchItem?.searchField, let w = window else { return }
        searchExplicit = true
        searchItem?.beginSearchInteraction()
        w.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
    }

    // MARK: NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [studyID, .sidebarTrackingSeparator, navID, .flexibleSpace, modeID, fontID, searchID]
    }

    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, navID, modeID, .flexibleSpace, fontID, searchID]
    }

    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        switch id {
        case navID:
            let g = NSToolbarItemGroup(itemIdentifier: id,
                                       images: [NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "后退")!,
                                                NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "前进")!],
                                       selectionMode: .momentary, labels: ["后退 (⌘[)", "前进 (⌘])"],
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
            // Icon + label per segment (icons match Settings › 词典 / 记词 tabs; neither localizes).
            let c = NSSegmentedControl(labels: Mode.allCases.map(\.rawValue), trackingMode: .selectOne,
                                       target: self, action: #selector(modeSeg(_:)))
            let menu = NSMenu(title: "模式")
            for (i, m) in Mode.allCases.enumerated() {
                let img = NSImage(systemSymbolName: m.symbol, accessibilityDescription: m.rawValue)?
                    .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
                c.setImage(img, forSegment: i)
                c.setImageScaling(.scaleProportionallyDown, forSegment: i)
                let mi = NSMenuItem(title: m.rawValue, action: #selector(modeMenu(_:)), keyEquivalent: "")
                mi.target = self; mi.tag = i; mi.image = NSImage(systemSymbolName: m.symbol, accessibilityDescription: nil)
                menu.addItem(mi)
            }
            c.segmentStyle = .automatic
            c.selectedSegment = Mode.allCases.firstIndex(of: state.mode) ?? 0
            let it = NSToolbarItem(itemIdentifier: id)
            it.view = c; it.label = "模式"
            let top = NSMenuItem(title: "模式", action: nil, keyEquivalent: ""); top.submenu = menu
            it.menuFormRepresentation = top
            modeControl = c
            return it
        case fontID:
            let g = NSToolbarItemGroup(itemIdentifier: id,
                                       images: [Self.glyph("小", size: 9.5), Self.glyph("大", size: 12)],
                                       selectionMode: .momentary,
                                       labels: ["缩小文字", "放大文字"], target: self, action: #selector(font(_:)))
            g.label = "文字大小"
            g.controlRepresentation = .expanded
            g.autovalidates = false
            g.subitems.forEach { $0.autovalidates = false; $0.isEnabled = true }
            fontGroup = g
            return g
        case newBookID:
            let it = NSToolbarItem(itemIdentifier: id)
            it.image = NSImage(systemSymbolName: "book.badge.plus", accessibilityDescription: "新建生词本")
            it.label = "新建生词本"
            it.toolTip = "新建生词本 (⇧⌘N)"
            let b = NSButton(image: NSImage(systemSymbolName: "book.badge.plus", accessibilityDescription: "新建生词本")!,
                             target: self, action: #selector(newBook(_:)))
            b.bezelStyle = .toolbar
            b.toolTip = it.toolTip
            b.setAccessibilityLabel("新建生词本")
            it.view = b
            // View-based: a plain image item placed before the tracking separator stayed in the overflow menu.
            it.autovalidates = false
            it.visibilityPriority = .high
            return it
        case studyID:
            let it = NSToolbarItem(itemIdentifier: id)
            let b = NSButton(title: "计划", image: NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)!,
                             target: self, action: #selector(openPlan))
            b.bezelStyle = .toolbar
            b.imagePosition = .imageLeading
            b.toolTip = "背诵计划 (⌥⌘P)"
            it.view = b
            it.label = "计划"
            it.toolTip = b.toolTip
            // Shown in » when the window is too narrow.
            let m = NSMenuItem(title: "计划", action: #selector(openPlan), keyEquivalent: ""); m.target = self
            m.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)
            it.menuFormRepresentation = m
            it.autovalidates = false
            return it
        case searchID:
            let s = NSSearchToolbarItem(itemIdentifier: id)
            s.searchField.placeholderString = "搜索"
            s.searchField.delegate = self
            s.searchField.sendsSearchStringImmediately = true
            // The ⓧ cancel button clears via the action, not always via controlTextDidChange.
            s.searchField.target = self
            s.searchField.action = #selector(searchFieldAction(_:))
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
        if g.selectedIndex == 0 { AppNav.shared.back() } else { AppNav.shared.forward() }
    }

    @objc private func modeSeg(_ c: NSSegmentedControl) { setMode(c.selectedSegment) }
    @objc private func modeMenu(_ m: NSMenuItem) { setMode(m.tag) }
    private func setMode(_ i: Int) {
        if Mode.allCases.indices.contains(i) { state.mode = Mode.allCases[i] }
        modeControl?.selectedSegment = Mode.allCases.firstIndex(of: state.mode) ?? 0
    }

    @objc private func openPlan() { state.openPlan() }

    @objc private func newBook(_ sender: Any?) { WordbookModel.shared.promptNewBook() }

    @objc private func font(_ g: NSToolbarItemGroup) {
        if g.selectedIndex == 0 { lookup.zoomOut() } else { lookup.zoomIn() }
    }

    // MARK: search field

    func controlTextDidChange(_ n: Notification) {
        guard let f = n.object as? NSSearchField else { return }
        // IME composition (pinyin marked text): wait for the committed text.
        if let tv = f.currentEditor() as? NSTextView, tv.hasMarkedText() { return }
        // A quiz is on screen and the user didn't choose to search: don't let stray typing leave it.
        if QuizFocus.quizActive && !searchExplicit { return }
        switch state.mode {
        case .words:
            state.wordFilter = f.stringValue
            // Searching from 今日 shows matches across all words.
            if state.wordGroup == .today && !f.stringValue.isEmpty { state.wordGroup = .all }
        case .lookup: lookup.query = f.stringValue
        }
    }

    @objc private func searchFieldAction(_ f: NSSearchField) {
        if let tv = f.currentEditor() as? NSTextView, tv.hasMarkedText() { return }
        switch state.mode {
        case .words: if state.wordFilter != f.stringValue { state.wordFilter = f.stringValue }
        case .lookup: if lookup.query != f.stringValue { lookup.query = f.stringValue }
        }
    }

    func searchFieldDidEndSearching(_ f: NSSearchField) { searchFieldAction(f) }

    func controlTextDidEndEditing(_ n: Notification) {
        if (n.object as? NSSearchField) === searchItem?.searchField { searchExplicit = false }
    }

    // MARK: quiz keeps the keyboard

    private var searchFocused: Bool {
        guard let f = searchItem?.searchField, let tv = window?.firstResponder as? NSTextView else { return false }
        return tv.delegate === f || f.currentEditor() === tv
    }

    /// Take the caret out of the search field unless the user put it there; the quiz's shortcuts then work.
    func reclaimFocusForQuiz() {
        // A new question: an old click into search (not in the last moment) no longer counts.
        if searchExplicit && Date().timeIntervalSince(searchExplicitAt) > 1.5 { searchExplicit = false }
        guard QuizFocus.shouldReclaim(quizActive: QuizFocus.quizActive, searchFocused: searchFocused, explicit: searchExplicit),
              let w = window else { return }
        w.makeFirstResponder(nil)
    }

    private func installQuizFocus() {
        guard focusMonitors.isEmpty else { return }
        // A click into the search field is an explicit choice to search.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] e in
            guard let self, let f = self.searchItem?.searchField, e.window === self.window, let v = f.superview else { return e }
            let p = v.convert(e.locationInWindow, from: nil)
            if f.frame.contains(p) { self.searchExplicit = true }
            return e
        }) { focusMonitors.append(m) }
        // Keys typed while the field has focus by accident (e.g. left from before the quiz) go to the quiz.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard let self, e.window === self.window else { return e }
            if QuizFocus.shouldReclaim(quizActive: QuizFocus.quizActive, searchFocused: self.searchFocused, explicit: self.searchExplicit) {
                self.window?.makeFirstResponder(nil)   // the event then reaches the quiz's key shortcuts
            }
            return e
        }) { focusMonitors.append(m) }
        // 词典: type anywhere to search (Dictionary.app). The keystroke is handed to the search field's
        // editor, so an input method (pinyin) starts composing there and nothing is dropped.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard let self, e.window === self.window, let w = self.window, let f = self.searchItem?.searchField else { return e }
            let textFocused = w.firstResponder is NSText || w.firstResponder is NSTextView
            let mods = e.modifierFlags
            // ⌘-shortcuts in the search field are handed straight to its editor: views in the window
            // (the entry WKWebView) otherwise claim ⌘V/⌘C/… as key equivalents before the Edit menu.
            let cmd = mods.intersection([.command, .control, .option, .shift])
            if mods.contains(.command), self.searchFocused, let ed = f.currentEditor() as? NSTextView {
                let k = e.charactersIgnoringModifiers?.lowercased() ?? ""
                switch (k, cmd) {
                case ("v", [.command]):
                    // Empty or fully selected field in 词典: replace and look up at once; else a normal paste.
                    let all = ed.selectedRange().location == 0 && ed.selectedRange().length == (ed.string as NSString).length
                    if self.state.mode == .lookup, all, let t = TypeToSearch.pasteQuery(NSPasteboard.general.string(forType: .string)) {
                        self.pasteLookup(t, f); return nil
                    }
                    ed.paste(nil); return nil
                case ("c", [.command]): ed.copy(nil); return nil
                case ("x", [.command]): ed.cut(nil); return nil
                case ("a", [.command]): ed.selectAll(nil); return nil
                case ("z", [.command]): ed.undoManager?.undo(); return nil
                case ("z", [.command, .shift]): ed.undoManager?.redo(); return nil
                default: return e
                }
            }
            // 词典, nothing text-focused: ⌘V looks the clipboard text up (one line, trimmed).
            if self.state.mode == .lookup, !textFocused, cmd == [.command], e.charactersIgnoringModifiers == "v" {
                guard let t = TypeToSearch.pasteQuery(NSPasteboard.general.string(forType: .string)) else { return e }
                self.pasteLookup(t, f)
                return nil
            }
            guard TypeToSearch.shouldRedirect(characters: e.characters, keyCode: e.keyCode,
                                              command: mods.contains(.command), control: mods.contains(.control),
                                              lookupMode: self.state.mode == .lookup, textFocused: textFocused) else { return e }
            self.focusSearch()
            guard let ed = f.currentEditor() else { return e }
            ed.keyDown(with: e)   // through the editor's input context: IME marked text lands in the field
            return nil
        }) { focusMonitors.append(m) }
        NotificationCenter.default.addObserver(forName: .vocabQuizQuestionShown, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reclaimFocusForQuiz() }
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
            // SwiftUI orders the window front before launch finishes, but the toolbar can only be
            // installed after that; keep the window transparent until it is, so the content
            // doesn't visibly jump down when the toolbar appears.
            if w.toolbar?.identifier != "vocab.main" {
                w.alphaValue = 0
                // Never leave it invisible, whatever happens.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if w.alphaValue == 0 { w.alphaValue = 1 } }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { MainToolbarController.shared.attach(to: w) } }
            // SwiftUI may install its own toolbar after us; re-assert once things settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { MainToolbarController.shared.attach(to: w) } }
        }
    }
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ v: NSView, context: Context) {}
}
