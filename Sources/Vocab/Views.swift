import SwiftUI
import VocabCore
import WebKit

enum Mode: String, CaseIterable, Identifiable {
    case lookup = "查词", wordbook = "生词本", review = "背单词"
    var id: String { rawValue }
}

struct MainView: View {
    @EnvironmentObject var lookup: LookupModel
    @EnvironmentObject var book: WordbookModel
    @State private var mode: Mode = .lookup
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            switch mode {
            case .lookup: LookupView()
            case .wordbook: WordbookView(onOpen: { w in mode = .lookup; lookup.search(w) })
            case .review: ReviewView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { lookup.back() } label: { Image(systemName: "chevron.left") }
                    .disabled(!lookup.canGoBack || mode != .lookup)
                    .help("返回")
            }
            ToolbarItem(placement: .principal) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { m in
                        Text(m == .review && !book.dueItems.isEmpty ? "背单词 \(book.dueItems.count)" : m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
            ToolbarItem(placement: .primaryAction) {
                if mode == .lookup {
                    TextField("搜索", text: $lookup.query)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .focused($searchFocused)
                        .onSubmit { lookup.commit() }
                        .onKeyPress(.downArrow) { lookup.moveSelection(1); return .handled }
                        .onKeyPress(.upArrow) { lookup.moveSelection(-1); return .handled }
                }
            }
        }
        .onChange(of: lookup.query) { _, _ in
            if mode == .lookup { lookup.queryChanged() }
        }
        .onAppear { searchFocused = true }
    }
}

struct LookupView: View {
    @EnvironmentObject var lookup: LookupModel
    @EnvironmentObject var book: WordbookModel

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 150, idealWidth: 190, maxWidth: 300)
            detail
                .frame(minWidth: 360)
        }
    }

    private var sidebar: some View {
        let matches = lookup.suggestions.filter { $0.kind == .match }
        let spelling = lookup.suggestions.filter { $0.kind == .spelling }
        return List(selection: Binding(get: { lookup.selection }, set: { lookup.select($0) })) {
            if !matches.isEmpty {
                ForEach(matches) { s in Text(s.word).lineLimit(1).tag(s.id) }
            }
            if !spelling.isEmpty {
                Section("你是不是要找：") {
                    ForEach(spelling) { s in Text(s.word).lineLimit(1).tag(s.id) }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if lookup.suggestions.isEmpty && !lookup.query.isEmpty {
                Text("无匹配").foregroundStyle(.secondary)
            }
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            if !lookup.entries.isEmpty {
                HStack(spacing: 4) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            tab("全部", selected: lookup.selectedDictionary == nil) { lookup.selectedDictionary = nil }
                            ForEach(lookup.dictionariesWithResults) { d in
                                tab(d.name, selected: lookup.selectedDictionary == d.id) { lookup.selectedDictionary = d.id }
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    Button {
                        lookup.addCurrentToWordbook()
                    } label: {
                        Label(book.contains(lookup.searchedTerm) ? "已在生词本" : "加入生词本",
                              systemImage: book.contains(lookup.searchedTerm) ? "star.fill" : "star")
                    }
                    .buttonStyle(.borderless)
                    .padding(.trailing, 14)
                }
                .padding(.vertical, 6)
                Divider()
            }
            ZStack(alignment: .bottom) {
                EntryWebView(entries: lookup.visibleEntries,
                             showTitles: lookup.selectedDictionary == nil,
                             emptyMessage: lookup.searchedTerm.isEmpty ? "输入单词开始查询" : "没有找到「\(lookup.searchedTerm)」",
                             onLookup: { lookup.search($0) })
                if let t = lookup.toast {
                    Text(t).padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 18)
                        .transition(.opacity)
                }
            }
        }
    }

    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(selected ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

/// WKWebView showing a set of dictionary entries.
struct EntryWebView: NSViewRepresentable {
    var entries: [DictionaryEntry]
    var showTitles: Bool
    var panel = false
    var emptyMessage: String
    var onLookup: (String) -> Void

    @MainActor final class Coordinator {
        let factory = EntryWebViewFactory()
        var token = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.factory.makeWebView()
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        context.coordinator.factory.onLookup = onLookup
        let token = entries.map(\.id).joined(separator: "|") + "\(showTitles)\(emptyMessage)"
        guard token != context.coordinator.token else { return }
        context.coordinator.token = token
        let url = EntryWebViewFactory.pageURL(for: entries, showTitles: showTitles, panel: panel, emptyMessage: emptyMessage)
        wv.load(URLRequest(url: url))
    }
}

struct WordbookView: View {
    @EnvironmentObject var book: WordbookModel
    var onOpen: (String) -> Void
    @State private var selection = Set<Int64>()
    @State private var filter = ""

    private var rows: [WordItem] {
        filter.isEmpty ? book.items : book.items.filter { $0.word.localizedCaseInsensitiveContains(filter) || $0.definition.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("筛选", text: $filter).textFieldStyle(.roundedBorder).frame(width: 200)
                Spacer()
                Text("共 \(book.items.count) 个，待复习 \(book.dueItems.count) 个").foregroundStyle(.secondary)
                Button("删除") { book.delete(selection); selection = [] }.disabled(selection.isEmpty)
                Button("导出 CSV…") { book.exportCSV() }.disabled(book.items.isEmpty)
            }
            .padding(10)
            Table(rows, selection: $selection) {
                TableColumn("单词") { Text($0.word).fontWeight(.semibold) }.width(min: 80, ideal: 120)
                TableColumn("释义") { Text($0.definition).lineLimit(2).help($0.definition) }
                TableColumn("来源") { Text($0.dictionary).foregroundStyle(.secondary) }.width(min: 60, ideal: 120)
                TableColumn("加入时间") { Text($0.added, format: .dateTime.year().month().day()) }.width(90)
                TableColumn("下次复习") { Text($0.review.due, format: .relative(presentation: .named)) }.width(100)
            }
            .contextMenu(forSelectionType: Int64.self) { ids in
                Button("查词") { if let id = ids.first, let w = book.items.first(where: { $0.id == id }) { onOpen(w.word) } }
                Button("删除") { book.delete(ids) }
            } primaryAction: { ids in
                if let id = ids.first, let w = book.items.first(where: { $0.id == id }) { onOpen(w.word) }
            }
            .overlay { if book.items.isEmpty { Text("生词本还是空的。查词时点「加入生词本」或按 ⌘D。").foregroundStyle(.secondary) } }
        }
        .onAppear { book.reload() }
    }
}

struct ReviewView: View {
    @EnvironmentObject var book: WordbookModel
    @State private var revealed = false
    @State private var entries: [DictionaryEntry] = []

    var body: some View {
        VStack(spacing: 18) {
            if let item = book.dueItems.first {
                Text("待复习 \(book.dueItems.count)").foregroundStyle(.secondary).padding(.top, 20)
                Text(item.word).font(.system(size: 44, weight: .semibold, design: .serif))
                if let c = item.context, !c.isEmpty {
                    Text(c).italic().foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
                }
                if revealed {
                    EntryWebView(entries: entries, showTitles: false, panel: true,
                                 emptyMessage: item.definition, onLookup: { _ in })
                        .frame(maxWidth: 720)
                        .overlay(alignment: .topTrailing) {
                            if entries.isEmpty { EmptyView() }
                        }
                    HStack(spacing: 16) {
                        ForEach(ReviewRating.allCases, id: \.self) { r in
                            Button("\(r.label)  \(r.rawValue)") { rate(item, r) }
                                .keyboardShortcut(KeyEquivalent(Character("\(r.rawValue)")), modifiers: [])
                                .controlSize(.large)
                        }
                    }
                    .padding(.bottom, 24)
                } else {
                    Spacer()
                    Button("显示释义（空格）") { reveal(item) }
                        .keyboardShortcut(.space, modifiers: [])
                        .controlSize(.large)
                        .padding(.bottom, 40)
                }
            } else {
                Spacer()
                Image(systemName: "checkmark.circle").font(.system(size: 48)).foregroundStyle(.green)
                Text("今天没有要复习的单词").font(.title3)
                Text("生词本共 \(book.items.count) 个").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { book.reload() }
    }

    private func reveal(_ item: WordItem) {
        let dicts = DictionarySelection.enabled()
        entries = Array(DictionaryService.shared.lookup(item.word, in: dicts).filter { $0.dictionary.name == item.dictionary }.prefix(2))
        revealed = true
    }

    private func rate(_ item: WordItem, _ r: ReviewRating) {
        book.rate(item, r)
        revealed = false
        entries = []
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsModel
    @State private var dicts: [DictionaryInfo] = []
    @State private var enabled: [String] = []

    var body: some View {
        TabView {
            Form {
                Section {
                    Toggle("接管三指查词", isOn: Binding(get: { settings.takeoverEnabled }, set: { settings.setTakeover($0) }))
                    Text("打开后：关闭系统「触控板 › 查询与数据检测器（三指轻点）」，改由「生词」弹出释义；关闭或退出「生词」时恢复你原来的系统设置。")
                        .font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("状态：辅助功能 \(settings.accessibilityTrusted ? "已授权 ✓" : "未授权 ✗") · 触控板 \(settings.multitouchDevices) 个 · 触摸帧 \(settings.frames)")
                        Text("上次三指轻点：\(settings.lastTap.map { $0.formatted(date: .omitted, time: .standard) } ?? "还没有检测到")")
                        Text("日志：~/Library/Logs/Vocab/vocab.log").foregroundStyle(.secondary)
                    }
                    .font(.caption.monospacedDigit())
                    .textSelection(.enabled)
                    if let e = settings.lastError { Text(e).foregroundStyle(.red).font(.caption) }
                }
                Section("辅助功能权限") {
                    HStack {
                        Image(systemName: settings.accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(settings.accessibilityTrusted ? .green : .orange)
                        Text(settings.accessibilityTrusted ? "已授权，可以读取光标下的单词" : "未授权：三指查词需要读取光标下的文字")
                        Spacer()
                        if !settings.accessibilityTrusted {
                            Button("去授权") { WordUnderCursor.requestTrust(); WordUnderCursor.openAccessibilitySettings() }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .onAppear { settings.refreshTrust(); settings.startStatusUpdates() }
            .tabItem { Label("通用", systemImage: "gearshape") }

            DictionarySettingsView()
            .tabItem { Label("词典", systemImage: "books.vertical") }
        }
    }
}
