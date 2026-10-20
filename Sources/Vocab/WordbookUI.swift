import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VocabCore

/// Sidebar grouping in 生词本 mode: a wordbook, a tag or a source. Filters live in the bar above the table.
enum WordGroup: Hashable {
    case all
    case book(Int64)
    case tag(String)
    case source(String)
}

/// Which words of the group the table shows (scope bar, left).
enum WordbookScope: String, CaseIterable, Identifiable {
    case all = "全部", due = "待复习", recent = "最近加入"
    var id: String { rawValue }
}

extension WordItem {
    /// Sidebar 来源 group: the app the word came from.
    var sourceGroup: String { sourceApp?.isEmpty == false ? sourceApp! : "其他" }
}

@MainActor
final class WordbookModel: ObservableObject {
    static let shared = WordbookModel()
    @Published private(set) var items: [WordItem] = []
    @Published private(set) var dueItems: [WordItem] = []
    @Published private(set) var books: [Wordbook] = []
    @Published private(set) var tags: [(tag: String, count: Int)] = []
    @Published var toast: String?
    let store: WordStore?

    init() {
        store = try? WordStore(url: WordStore.defaultURL())
        reload()
    }

    init(store: WordStore?) { self.store = store; reload() }

    func reload() {
        items = (try? store?.all()) ?? []
        dueItems = (try? store?.due()) ?? []
        books = (try? store?.books()) ?? []
        tags = (try? store?.allTags()) ?? []
    }

    /// Source groups with counts, most used first.
    var sources: [(name: String, count: Int)] {
        Dictionary(grouping: items, by: \.sourceGroup).map { ($0.key, $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var defaultBook: Wordbook? { books.first(where: \.isDefault) }

    func add(entry: DictionaryEntry, word: String, context: String?, surface: String? = nil, source: WordSource? = nil) {
        let lemma = Lemmatizer.lemma(of: surface ?? word, in: context)
        var book: Int64?
        if case .book(let id) = AppState.shared.wordGroup { book = id }
        _ = try? store?.add(word: word, definition: entry.snippet, dictionary: entry.dictionary.name, context: context,
                            surface: surface, lemma: lemma, source: source, book: book)
        reload()
    }

    /// Looking up a word that is already in the book records the new sentence too.
    func recordLookup(word: String, context: String?, surface: String?, source: WordSource?) {
        guard let c = context, let store, let w = (try? store.find(word: word)) ?? nil else { return }
        try? store.addContext(wordID: w.id, sentence: c, surface: surface, source: source)
        reload()
    }

    func contains(_ word: String) -> Bool { ((try? store?.find(word: word)) ?? nil) != nil }

    func delete(_ ids: Set<Int64>) {
        try? store?.transaction { for id in ids { try store?.delete(id: id) } }
        reload()
    }

    func rate(_ item: WordItem, _ r: ReviewRating) {
        _ = try? store?.review(id: item.id, rating: r)
        reload()
    }

    func retire(_ ids: Set<Int64>) {
        try? store?.transaction { for id in ids { _ = try store?.retire(id: id) } }
        reload()
    }

    func move(_ ids: Set<Int64>, to book: Int64) { try? store?.move(Array(ids), toBook: book); reload() }
    func addTag(_ tag: String, to ids: Set<Int64>) { try? store?.addTag(tag, to: Array(ids)); reload() }
    func removeTag(_ tag: String, from ids: Set<Int64>) { try? store?.removeTag(tag, from: Array(ids)); reload() }
    func setTags(_ id: Int64, _ tags: [String]) { try? store?.setTags(id: id, tags); reload() }
    func setNote(_ id: Int64, _ note: String) { try? store?.setNote(id: id, note); reload() }
    func contexts(_ id: Int64) -> [WordContext] { (try? store?.contexts(for: id)) ?? [] }
    func deleteContext(_ id: Int64) { try? store?.deleteContext(id: id); reload() }

    @discardableResult
    func createBook(_ name: String) -> Wordbook? { let b = try? store?.createBook(name); reload(); return b }
    func renameBook(_ id: Int64, _ name: String) { try? store?.renameBook(id, to: name); reload() }
    func setDefaultBook(_ id: Int64) { try? store?.setDefaultBook(id); reload() }
    func deleteBook(_ id: Int64) { try? store?.deleteBook(id); reload() }

    func flash(_ s: String) {
        toast = s
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); if toast == s { toast = nil } }
    }

    // MARK: Import / export

    func exportCSV(_ rows: [WordItem]? = nil) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "生词本.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // UTF-8 BOM so Excel/Numbers detect Chinese correctly.
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(CSVExporter.csv(rows ?? items, books: books).utf8)
        do { try data.write(to: url); flash("已导出 \((rows ?? items).count) 个单词") } catch { alert("导出失败", error) }
    }

    func exportAnki(_ rows: [WordItem]? = nil, deck: String = "生词本") {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apkg") ?? .data]
        panel.nameFieldStringValue = "\(deck).apkg"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try AnkiExporter.write(rows ?? items, deckName: deck, to: url); flash("已导出 \((rows ?? items).count) 张 Anki 填空卡") }
        catch { alert("导出失败", error) }
    }

    func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url, let store else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let r = try WordbookImporter.importCSV(text, into: store, book: currentBook)
            reload(); report(r)
        } catch { alert("导入失败", error) }
    }

    func importKindle() {
        let panel = NSOpenPanel()
        panel.message = "选择 Kindle 的 vocab.db（连接 Kindle 后在 system/vocabulary/ 里）"
        panel.allowedContentTypes = [UTType(filenameExtension: "db") ?? .data, .data]
        if let v = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes"))?.first(where: { $0.lowercased().contains("kindle") }) {
            panel.directoryURL = URL(fileURLWithPath: "/Volumes/\(v)/system/vocabulary")
        }
        guard panel.runModal() == .OK, let url = panel.url, let store else { return }
        do { let r = try WordbookImporter.importKindle(at: url, into: store, book: currentBook); reload(); report(r) }
        catch { alert("导入失败", error) }
    }

    private var currentBook: Int64? {
        if case .book(let id) = AppState.shared.wordGroup { return id }
        return nil
    }

    private func report(_ r: ImportResult) {
        flash("新增 \(r.added) 个，更新 \(r.updated) 个，原句 \(r.contexts) 条")
    }

    private func alert(_ title: String, _ error: Error) {
        let a = NSAlert(); a.messageText = title; a.informativeText = "\(error)"; a.runModal()
    }
}

// MARK: - Sidebar

struct WordbookSidebar: View {
    @EnvironmentObject var book: WordbookModel
    @ObservedObject var state = AppState.shared
    @State private var renaming: Wordbook?
    @State private var newName = ""
    @State private var creating = false

    var body: some View {
        List(selection: Binding(get: { state.wordGroup }, set: { if let g = $0 { state.wordGroup = g } })) {
            Section("生词本") {
                Label("所有单词", systemImage: "tray.full").badge(book.items.count).tag(WordGroup.all)
                ForEach(book.books) { b in
                    Label(b.name, systemImage: b.isDefault ? "book.closed.fill" : "book.closed")
                        .badge(book.items.filter { $0.bookID == b.id }.count)
                        .tag(WordGroup.book(b.id))
                        .dropDestination(for: String.self) { ids, _ in
                            book.move(Set(ids.compactMap { Int64($0) }), to: b.id); return true
                        }
                        .contextMenu {
                            Button("重命名…") { newName = b.name; renaming = b }
                            Button("设为默认生词本") { book.setDefaultBook(b.id) }.disabled(b.isDefault)
                            Divider()
                            Button("删除生词本…") { confirmDelete(b) }.disabled(b.isDefault)
                        }
                }
            }
            if !book.tags.isEmpty {
                Section("标签") {
                    ForEach(book.tags, id: \.tag) { t in
                        Label(t.tag, systemImage: "tag").badge(t.count).tag(WordGroup.tag(t.tag))
                    }
                }
            }
            if !book.sources.isEmpty {
                Section("来源") {
                    ForEach(book.sources, id: \.name) { s in
                        Label(s.name, systemImage: icon(s.name)).badge(s.count).tag(WordGroup.source(s.name))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { newName = ""; creating = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("新建生词本")
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .alert("新建生词本", isPresented: $creating) {
            TextField("名称", text: $newName)
            Button("创建") { if let b = book.createBook(newName) { state.wordGroup = .book(b.id) } }
            Button("取消", role: .cancel) {}
        }
        .alert("重命名生词本", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名称", text: $newName)
            Button("好") { if let r = renaming { book.renameBook(r.id, newName) }; renaming = nil }
            Button("取消", role: .cancel) { renaming = nil }
        }
    }

    private func icon(_ app: String) -> String {
        switch app {
        case "Safari", "Google Chrome", "Microsoft Edge", "Arc", "Brave Browser": return "globe"
        case "Kindle", "图书", "Books": return "books.vertical"
        default: return "app"
        }
    }

    private func confirmDelete(_ b: Wordbook) {
        let a = NSAlert()
        a.messageText = "删除生词本「\(b.name)」？"
        a.informativeText = "其中的单词会移到默认生词本，不会被删除。"
        a.addButton(withTitle: "删除"); a.addButton(withTitle: "取消")
        a.buttons.first?.hasDestructiveAction = true
        if a.runModal() == .alertFirstButtonReturn {
            book.deleteBook(b.id)
            if state.wordGroup == .book(b.id) { state.wordGroup = .all }
        }
    }
}

// MARK: - Main pane

struct WordbookView: View {
    @EnvironmentObject var book: WordbookModel
    var onOpen: (String) -> Void
    @ObservedObject var state = AppState.shared
    @State private var selection = Set<Int64>()

    private var rows: [WordItem] {
        var base: [WordItem]
        switch state.wordScope {
        case .all: base = book.items
        case .due: base = book.dueItems
        case .recent: base = book.items.filter { $0.added > Date().addingTimeInterval(-7 * 86400) }
        }
        switch state.wordGroup {
        case .all: break
        case .book(let id): base = base.filter { $0.bookID == id }
        case .tag(let t): base = base.filter { $0.tags.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }
        case .source(let s): base = base.filter { $0.sourceGroup == s }
        }
        if let f = state.wordFamiliarity { base = base.filter { $0.familiarity == f } }
        let q = state.wordFilter.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            base = base.filter {
                $0.word.localizedCaseInsensitiveContains(q) || $0.definition.localizedCaseInsensitiveContains(q)
                    || $0.note.localizedCaseInsensitiveContains(q) || ($0.context ?? "").localizedCaseInsensitiveContains(q)
                    || $0.tags.contains { $0.localizedCaseInsensitiveContains(q) }
            }
        }
        return base
    }

    private var groupTitle: String {
        switch state.wordGroup {
        case .all: return "所有单词"
        case .book(let id): return book.books.first { $0.id == id }?.name ?? "生词本"
        case .tag(let t): return t
        case .source(let s): return s
        }
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            filterBar(count: rows.count, rows: rows)
            Divider()
            VSplitView {
                WordTable(rows: rows, books: book.books, selection: $selection, onOpen: onOpen)
                    .frame(minHeight: 160)
                    .overlay { if book.items.isEmpty { Text("生词本还是空的。查词时点「加入生词本」或按 ⌘D。").foregroundStyle(.secondary) }
                               else if rows.isEmpty { Text("没有符合条件的单词").foregroundStyle(.secondary) } }
                if selection.count == 1, let id = selection.first, let w = book.items.first(where: { $0.id == id }) {
                    WordDetailView(item: w, onOpen: onOpen)
                        .frame(minHeight: 160, idealHeight: 240)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let t = book.toast {
                Text(t).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule()).padding(.bottom, 18)
            }
        }
        .onAppear { book.reload() }
        .onChange(of: state.wordGroup) { _, _ in selection = [] }
    }

    /// Finder-style scope bar: what to show on the left, familiarity next to it, actions on the right.
    private func filterBar(count: Int, rows: [WordItem]) -> some View {
        HStack(spacing: 10) {
            Picker("", selection: $state.wordScope) {
                ForEach(WordbookScope.allCases) { s in Text(s.rawValue).tag(s) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Picker("", selection: $state.wordFamiliarity) {
                Text("全部熟悉度").tag(Familiarity?.none)
                Divider()
                ForEach(Familiarity.allCases) { f in Text(f.title).tag(Familiarity?.some(f)) }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()
            .help("按熟悉度筛选")
            Spacer()
            Text("\(groupTitle) · \(count) 个").foregroundStyle(.secondary).lineLimit(1)
            Menu {
                Button("CSV…") { book.importCSV() }
                Button("Kindle 生词本（vocab.db）…") { book.importKindle() }
            } label: { Text("导入") }
            .menuStyle(.borderlessButton).fixedSize()
            Menu {
                Button("CSV…") { book.exportCSV(rows) }
                Button("Anki 卡片包（.apkg）…") { book.exportAnki(rows, deck: groupTitle) }
            } label: { Text("导出") }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(rows.isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

// MARK: - Table (AppKit)

struct WordTable: NSViewRepresentable {
    var rows: [WordItem]
    var books: [Wordbook]
    @Binding var selection: Set<Int64>
    var onOpen: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTableView()
        tv.style = .inset
        tv.usesAlternatingRowBackgroundColors = true
        tv.allowsMultipleSelection = true
        tv.allowsColumnReordering = true
        tv.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tv.autosaveName = "VocabWordTable"
        let cols: [(String, String, CGFloat, String?)] = [
            ("word", "单词", 120, "word"), ("definition", "释义", 260, nil), ("source", "来源", 130, "source"),
            ("familiarity", "熟悉度", 64, "familiarity"), ("added", "加入时间", 90, "added"), ("due", "下次复习", 90, "due"),
        ]
        for (id, title, w, sortKey) in cols {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title; c.width = w; c.minWidth = 50
            if let k = sortKey { c.sortDescriptorPrototype = NSSortDescriptor(key: k, ascending: k != "added") }
            else { c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true) }
            tv.addTableColumn(c)
        }
        tv.autosaveTableColumns = true
        tv.delegate = context.coordinator
        tv.dataSource = context.coordinator
        tv.target = context.coordinator
        tv.doubleAction = #selector(Coordinator.doubleClick(_:))
        let menu = NSMenu(); menu.delegate = context.coordinator; tv.menu = menu
        tv.setDraggingSourceOperationMask(.move, forLocal: true)
        let st = AppState.shared
        tv.sortDescriptors = [NSSortDescriptor(key: st.wordSortKey, ascending: st.wordSortAscending)]
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.table = tv
        context.coordinator.parent = self
        context.coordinator.reload()
        // Back from a word's details: restore where the list was.
        if let y = st.wordTableScroll {
            DispatchQueue.main.async { scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView) }
        }
        context.coordinator.observe(scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.reload()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource, NSMenuDelegate {
        var parent: WordTable
        weak var table: NSTableView?
        var sorted: [WordItem] = []
        private var lastToken = ""
        private var syncing = false
        private var scrollObs: Any?
        init(_ p: WordTable) { parent = p }

        func observe(_ scroll: NSScrollView) {
            scroll.contentView.postsBoundsChangedNotifications = true
            scrollObs = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak scroll] _ in
                MainActor.assumeIsolated { if let y = scroll?.contentView.bounds.origin.y { AppState.shared.wordTableScroll = y } }
            }
        }

        func sortRows() {
            let st = AppState.shared
            let k = st.wordSortKey, asc = st.wordSortAscending
            func cmp(_ a: WordItem, _ b: WordItem) -> Bool {
                let r: ComparisonResult
                switch k {
                case "definition": r = a.definition.localizedStandardCompare(b.definition)
                case "source": r = a.sourceLabel.localizedStandardCompare(b.sourceLabel)
                case "familiarity": r = a.familiarity.rawValue == b.familiarity.rawValue ? .orderedSame : a.familiarity.rawValue < b.familiarity.rawValue ? .orderedAscending : .orderedDescending
                case "added": r = a.added == b.added ? .orderedSame : a.added < b.added ? .orderedAscending : .orderedDescending
                case "due": r = a.review.due == b.review.due ? .orderedSame : a.review.due < b.review.due ? .orderedAscending : .orderedDescending
                default: r = a.word.localizedCaseInsensitiveCompare(b.word)
                }
                if r == .orderedSame { return a.id > b.id }
                return asc ? r == .orderedAscending : r == .orderedDescending
            }
            sorted = parent.rows.sorted(by: cmp)
        }

        func reload() {
            guard let tv = table else { return }
            sortRows()
            let token = sorted.map { "\($0.id):\($0.word):\($0.definition.count):\($0.sourceLabel):\($0.familiarity.rawValue):\($0.review.due.timeIntervalSince1970)" }.joined(separator: ",")
            if token != lastToken { lastToken = token; tv.reloadData() }
            syncing = true
            let idx = IndexSet(sorted.enumerated().filter { parent.selection.contains($0.element.id) }.map(\.offset))
            if tv.selectedRowIndexes != idx { tv.selectRowIndexes(idx, byExtendingSelection: false) }
            syncing = false
        }

        func numberOfRows(in tableView: NSTableView) -> Int { sorted.count }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let d = tableView.sortDescriptors.first, let k = d.key else { return }
            AppState.shared.wordSortKey = k; AppState.shared.wordSortAscending = d.ascending
            lastToken = ""; reload()
        }

        func tableViewSelectionDidChange(_ n: Notification) {
            guard !syncing, let tv = table else { return }
            let ids = Set(tv.selectedRowIndexes.compactMap { $0 < sorted.count ? sorted[$0].id : nil })
            if ids != parent.selection { parent.selection = ids }
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            row < sorted.count ? String(sorted[row].id) as NSString : nil
        }

        func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
            guard let col, row < sorted.count else { return nil }
            let w = sorted[row]
            let id = col.identifier.rawValue
            if id == "source", let s = w.sourceURL, let url = URL(string: s) {
                let b = NSButton(title: w.sourceLabel, target: self, action: #selector(openSource(_:)))
                b.isBordered = false; b.bezelStyle = .inline
                b.contentTintColor = .linkColor
                b.alignment = .left
                b.lineBreakMode = .byTruncatingTail
                b.toolTip = url.absoluteString
                b.tag = row
                b.font = .systemFont(ofSize: NSFont.systemFontSize)
                return b
            }
            let cell = (tableView.makeView(withIdentifier: col.identifier, owner: nil) as? NSTableCellView) ?? {
                let c = NSTableCellView(); c.identifier = col.identifier
                let t = NSTextField(labelWithString: ""); t.lineBreakMode = .byTruncatingTail
                t.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(t); c.textField = t
                NSLayoutConstraint.activate([t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                                             t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                                             t.centerYAnchor.constraint(equalTo: c.centerYAnchor)])
                return c
            }()
            let t = cell.textField!
            t.textColor = .labelColor
            t.font = .systemFont(ofSize: NSFont.systemFontSize)
            t.toolTip = nil
            switch id {
            case "word":
                t.stringValue = w.word; t.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
                if let l = w.lemma { t.toolTip = "原形：\(l)" }
            case "definition": t.stringValue = w.definition.replacingOccurrences(of: "\n", with: " "); t.toolTip = w.definition
            case "source": t.stringValue = w.sourceLabel; t.textColor = .secondaryLabelColor
            case "familiarity": t.stringValue = w.familiarity.title; t.textColor = .secondaryLabelColor
            case "added": t.stringValue = w.added.formatted(date: .numeric, time: .omitted)
            case "due":
                if w.familiarity == .retired { t.stringValue = "已斩"; t.textColor = .secondaryLabelColor }
                else { t.stringValue = w.review.due.formatted(.relative(presentation: .named)) }
            default: t.stringValue = ""
            }
            return cell
        }

        @objc func openSource(_ b: NSButton) {
            guard b.tag < sorted.count, let s = sorted[b.tag].sourceURL, let u = URL(string: s) else { return }
            NSWorkspace.shared.open(u)
        }

        @objc func doubleClick(_ tv: NSTableView) {
            let r = tv.clickedRow
            guard r >= 0, r < sorted.count else { return }
            parent.onOpen(sorted[r].word)
        }

        // MARK: Context menu

        /// Rows the menu acts on: the selection if the clicked row is in it, else just the clicked row.
        private var targets: Set<Int64> {
            guard let tv = table else { return [] }
            let r = tv.clickedRow
            if r >= 0, r < sorted.count, !tv.selectedRowIndexes.contains(r) { return [sorted[r].id] }
            return Set(tv.selectedRowIndexes.compactMap { $0 < sorted.count ? sorted[$0].id : nil })
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let ids = targets
            guard !ids.isEmpty else { return }
            func item(_ t: String, _ sel: Selector, _ obj: Any? = nil) -> NSMenuItem {
                let i = NSMenuItem(title: t, action: sel, keyEquivalent: ""); i.target = self; i.representedObject = obj; return i
            }
            if ids.count == 1 { menu.addItem(item("查词", #selector(lookUp))) }
            menu.addItem(item(ids.count == 1 ? "斩" : "斩（\(ids.count) 个）", #selector(retire)))
            menu.addItem(.separator())
            let move = NSMenuItem(title: "移到生词本", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let current = Set(parent.rows.filter { ids.contains($0.id) }.compactMap(\.bookID))
            for b in parent.books {
                let i = item(b.name, #selector(moveTo(_:)), b.id)
                if current == [b.id] { i.state = .on }
                sub.addItem(i)
            }
            sub.addItem(.separator()); sub.addItem(item("新建生词本…", #selector(moveToNew)))
            move.submenu = sub; menu.addItem(move)
            let tagItem = NSMenuItem(title: "标签", action: nil, keyEquivalent: "")
            let tsub = NSMenu()
            let selected = parent.rows.filter { ids.contains($0.id) }
            for t in WordbookModel.shared.tags.map(\.tag) {
                let all = selected.allSatisfy { $0.tags.contains(t) }
                let i = item(t, #selector(toggleTag(_:)), t); i.state = all ? .on : selected.contains { $0.tags.contains(t) } ? .mixed : .off
                tsub.addItem(i)
            }
            if tsub.numberOfItems > 0 { tsub.addItem(.separator()) }
            tsub.addItem(item("添加标签…", #selector(addTag)))
            tagItem.submenu = tsub; menu.addItem(tagItem)
            menu.addItem(.separator())
            menu.addItem(item(ids.count == 1 ? "删除…" : "删除 \(ids.count) 个单词…", #selector(delete)))
        }

        @objc func lookUp() { if let id = targets.first, let w = sorted.first(where: { $0.id == id }) { parent.onOpen(w.word) } }
        @objc func retire() { WordbookModel.shared.retire(targets) }
        @objc func moveTo(_ i: NSMenuItem) { if let b = i.representedObject as? Int64 { WordbookModel.shared.move(targets, to: b) } }
        @objc func moveToNew() {
            let ids = targets
            guard let name = Self.ask("新建生词本", "名称", ""), let b = WordbookModel.shared.createBook(name) else { return }
            WordbookModel.shared.move(ids, to: b.id)
        }
        @objc func toggleTag(_ i: NSMenuItem) {
            guard let t = i.representedObject as? String else { return }
            if i.state == .on { WordbookModel.shared.removeTag(t, from: targets) } else { WordbookModel.shared.addTag(t, to: targets) }
        }
        @objc func addTag() {
            let ids = targets
            guard let t = Self.ask("添加标签", "标签名，多个用逗号分隔", "") else { return }
            for tag in t.split(whereSeparator: { ",，;；".contains($0) }) {
                WordbookModel.shared.addTag(tag.trimmingCharacters(in: .whitespaces), to: ids)
            }
        }
        @objc func delete() {
            let ids = targets
            let a = NSAlert()
            let words = sorted.filter { ids.contains($0.id) }.map(\.word)
            a.messageText = ids.count == 1 ? "删除「\(words.first ?? "")」？" : "删除 \(ids.count) 个单词？"
            a.informativeText = "单词的原句、笔记、标签和复习记录都会一起删除，无法撤销。"
            a.addButton(withTitle: "删除"); a.addButton(withTitle: "取消")
            a.buttons.first?.hasDestructiveAction = true
            guard a.runModal() == .alertFirstButtonReturn else { return }
            WordbookModel.shared.delete(ids)
            parent.selection.subtract(ids)
        }

        static func ask(_ title: String, _ placeholder: String, _ value: String) -> String? {
            let a = NSAlert(); a.messageText = title
            let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); f.placeholderString = placeholder; f.stringValue = value
            a.accessoryView = f
            a.addButton(withTitle: "好"); a.addButton(withTitle: "取消")
            a.window.initialFirstResponder = f
            guard a.runModal() == .alertFirstButtonReturn else { return nil }
            let s = f.stringValue.trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? nil : s
        }
    }
}

// MARK: - Details

struct WordDetailView: View {
    let item: WordItem
    var onOpen: (String) -> Void
    @EnvironmentObject var book: WordbookModel
    @State private var note = ""
    @State private var tagText = ""
    @State private var editingNote = false
    @State private var contexts: [WordContext] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.word).font(.title2.weight(.semibold))
                    if let l = item.lemma { Text("原形 \(l)").foregroundStyle(.secondary) }
                    Text(item.familiarity.title).font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                    Spacer()
                    Button("查词") { onOpen(item.word) }.controlSize(.small)
                }
                if !item.definition.isEmpty { Text(item.definition).foregroundStyle(.secondary).textSelection(.enabled) }

                section("原句") {
                    if contexts.isEmpty { Text("没有原句").foregroundStyle(.tertiary) }
                    ForEach(contexts) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(highlight(c.sentence, c.surface ?? item.word)).textSelection(.enabled)
                            HStack(spacing: 6) {
                                if let s = c.sourceURL, let u = URL(string: s) {
                                    Link(c.sourceTitle ?? u.host ?? s, destination: u).lineLimit(1)
                                } else if let t = c.sourceTitle ?? c.sourceApp { Text(t).lineLimit(1) }
                                if c.sourceURL != nil || c.sourceTitle != nil, let a = c.sourceApp { Text("· \(a)") }
                                Text("· " + c.added.formatted(date: .abbreviated, time: .omitted))
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .contextMenu { Button("删除这条原句") { book.deleteContext(c.id); contexts = book.contexts(item.id) } }
                    }
                }

                section("标签") {
                    TextField("用逗号分隔，例如：GRE, 考研", text: $tagText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveTags)
                }

                section("笔记") {
                    if editingNote || note.isEmpty {
                        TextEditor(text: $note)
                            .font(.body).frame(minHeight: 70)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                        HStack {
                            Text("支持 Markdown").font(.caption).foregroundStyle(.tertiary)
                            Spacer()
                            if editingNote { Button("完成") { saveNote(); editingNote = false }.controlSize(.small) }
                        }
                    } else {
                        Text(markdown(note)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { editingNote = true }
                        Button("编辑笔记") { editingNote = true }.controlSize(.small)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear(perform: load)
        .onChange(of: item.id) { old, _ in flush(old); load() }
        .onDisappear { flush(item.id) }
    }

    private func load() {
        note = item.note; tagText = item.tags.joined(separator: ", "); editingNote = false
        contexts = book.contexts(item.id)
    }

    /// Save unsaved edits when switching rows or leaving.
    private func flush(_ id: Int64) {
        guard let cur = book.items.first(where: { $0.id == id }) else { return }
        if note != cur.note { book.setNote(id, note) }
        let tags = parsedTags
        if tags != cur.tags.sorted() { book.setTags(id, tags) }
    }

    private var parsedTags: [String] {
        Array(Set(tagText.split(whereSeparator: { ",，;；".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted()
    }

    private func saveTags() { book.setTags(item.id, parsedTags) }
    private func saveNote() { book.setNote(item.id, note) }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    private func highlight(_ sentence: String, _ word: String) -> AttributedString {
        var a = AttributedString(sentence)
        if let r = a.range(of: word, options: .caseInsensitive) { a[r].font = .body.bold() }
        return a
    }
}
