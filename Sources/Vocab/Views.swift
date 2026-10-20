import SwiftUI
import VocabCore
import WebKit

enum Mode: String, CaseIterable, Identifiable {
    case lookup = "查词", wordbook = "生词本", review = "背单词"
    var id: String { rawValue }
}

extension Notification.Name {
    static let vocabFocusSearch = Notification.Name("VocabFocusSearch")
}

/// Sidebar rows: suggestions while typing, recent lookups otherwise.
enum SidebarItem: Hashable {
    case suggestion(String)   // Suggestion.ID
    case recent(String)
}

/// Main window laid out like Dictionary.app. The AppKit toolbar (MainToolbar.swift) switches
/// between the three peer modes 词典 · 生词本 · 背单词; the sidebar follows the mode.
struct MainView: View {
    @EnvironmentObject var lookup: LookupModel
    @EnvironmentObject var book: WordbookModel
    @ObservedObject var state = AppState.shared
    @State private var sidebarSelection: SidebarItem?
    @State private var columns: NavigationSplitViewVisibility = .detailOnly   // empty query at launch: collapsed

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .navigationSplitViewColumnWidth(min: 150, ideal: 190, max: 300)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch state.mode {
                case .lookup: LookupDetailView()
                case .wordbook: WordbookView(onOpen: { w in openWord(w) })
                case .review: ReviewView()
                }
            }
            .frame(minWidth: 420)
        }
        .background(WindowToolbarInstaller())
        .navigationTitle("生词")
        .onChange(of: lookup.query) { _, q in
            // Like Dictionary.app: empty field collapses the sidebar, typing brings it back.
            if state.mode == .lookup {
                let want: NavigationSplitViewVisibility = q.trimmingCharacters(in: .whitespaces).isEmpty ? .detailOnly : .all
                if columns != want { withAnimation { columns = want } }
            }
            if lookup.suppressQueryChange { lookup.suppressQueryChange = false; return }
            if state.mode != .lookup { return }
            lookup.queryChanged()
        }
        .onChange(of: lookup.selection) { _, id in
            if let id, state.mode == .lookup { sidebarSelection = .suggestion(id) }
        }
        .onChange(of: state.mode) { _, m in
            // 背单词 needs no list: hide the sidebar there, like a focused mode.
            columns = m == .review ? .detailOnly
                : m == .lookup && lookup.query.trimmingCharacters(in: .whitespaces).isEmpty ? .detailOnly : .all
            sidebarSelection = nil
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NotificationCenter.default.post(name: .vocabFocusSearch, object: nil) } }
    }

    private var showingSuggestions: Bool {
        !lookup.query.trimmingCharacters(in: .whitespaces).isEmpty && !lookup.suggestions.isEmpty
    }

    @ViewBuilder private var sidebar: some View {
        if state.mode == .wordbook {
            WordbookSidebar()
        } else {
            let content = SidebarContent.make(query: lookup.query, suggestionsFor: lookup.suggestionsQuery,
                                              words: lookup.suggestions.map(\.word), recents: lookup.recents)
            let matches = lookup.suggestions.filter { $0.kind == .match }
            let spelling = lookup.suggestions.filter { $0.kind == .spelling }
            List(selection: Binding(get: { sidebarSelection }, set: { pick($0) })) {
                switch content {
                case .suggestions:
                    if !matches.isEmpty {
                        Section { ForEach(matches) { s in Text(s.word).lineLimit(1).tag(SidebarItem.suggestion(s.id)) } }
                    }
                    if !spelling.isEmpty {
                        Section("你是不是要找：") {
                            ForEach(spelling) { s in Text(s.word).lineLimit(1).tag(SidebarItem.suggestion(s.id)) }
                        }
                    }
                case .noSuggestions:
                    Text("无建议").foregroundStyle(.secondary).selectionDisabled()
                case .recents(let words):
                    // Like Dictionary.app: plain history, no header; the current word is a bold pill.
                    ForEach(words, id: \.self) { w in
                        Text(w).lineLimit(1)
                            .font(.system(size: 15, weight: sidebarSelection == .recent(w) ? .bold : .regular))
                            .tag(SidebarItem.recent(w))
                    }
                }
            }
            .listStyle(.sidebar)
            .contextMenu {
                if !lookup.recents.isEmpty { Button("清除最近查询") { lookup.clearRecents() } }
            }
        }
    }

    private func pick(_ item: SidebarItem?) {
        sidebarSelection = item
        switch item {
        case .suggestion(let id)?: lookup.select(id)
        case .recent(let w)?: lookup.open(w)
        case nil: break
        }
    }

    private func openWord(_ w: String) {
        state.mode = .lookup
        sidebarSelection = .recent(w)
        lookup.open(w)
    }
}

/// NSSearchField in the toolbar: ↑/↓ move through suggestions, ↩ opens, ⌘F / ⌘L focus it.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var onMove: (Int) -> Void
    var onCommit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = "搜索"
        f.delegate = context.coordinator
        f.sendsSearchStringImmediately = true
        f.focusRingType = .default
        context.coordinator.field = f
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: .vocabFocusSearch, object: nil, queue: .main) { [weak f] _ in
            MainActor.assumeIsolated {
                guard let f, let w = f.window else { return }
                w.makeFirstResponder(f)
                f.currentEditor()?.selectAll(nil)
            }
        }
        return f
    }

    func updateNSView(_ f: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        weak var field: NSSearchField?
        var observer: Any?
        init(_ p: SearchField) { parent = p }
        deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSSearchField, parent.text != f.stringValue { parent.text = f.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1); return true
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1); return true
            case #selector(NSResponder.insertNewline(_:)): parent.onCommit(); return true
            default: return false
            }
        }
    }
}

struct LookupDetailView: View {
    @EnvironmentObject var lookup: LookupModel
    @EnvironmentObject var book: WordbookModel

    var body: some View {
        VStack(spacing: 0) {
            DictionaryTabStrip(
                dictionaries: lookup.searchedTerm.isEmpty ? DictionarySelection.enabled() : lookup.dictionariesWithResults,
                selected: $lookup.selectedDictionary,
                trailing: {
                    if !lookup.entries.isEmpty {
                        Button { lookup.addCurrentToWordbook() } label: {
                            Image(systemName: book.contains(lookup.searchedTerm) ? "star.fill" : "star")
                        }
                        .buttonStyle(.borderless)
                        .help(book.contains(lookup.searchedTerm) ? "已在生词本" : "加入生词本 (⌘D)")
                    }
                })
            Divider()
            ZStack(alignment: .bottom) {
                if lookup.searchedTerm.isEmpty {
                    emptyState
                } else {
                    EntryWebView(entries: lookup.visibleEntries,
                                 showTitles: lookup.selectedDictionary == nil,
                                 emptyMessage: "没有找到「\(lookup.searchedTerm)」",
                                 zoom: lookup.zoom,
                                 onLookup: { lookup.search($0) })
                }
                if let t = lookup.toast {
                    Text(t).padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 18)
                        .transition(.opacity)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Like Dictionary.app: the prompt near the top, then the current dictionary — or, in 全部,
    /// every enabled dictionary, one per line — centred.
    private var emptyState: some View {
        let enabled = DictionarySelection.enabled()
        let names = lookup.selectedDictionary.flatMap { id in enabled.first { $0.id == id }.map { [$0.name] } } ?? enabled.map(\.name)
        return ScrollView {
            VStack(spacing: 14) {
                Text("请键入要查询的字词…")
                    .font(.system(size: 26, design: .serif))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 10)
                ForEach(names, id: \.self) { n in
                    Text(n).font(.system(size: 22, design: .serif)).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 120)
            .padding(.bottom, 40)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// Dictionary.app-style strip: 全部 + dictionary names as small pills; what doesn't fit goes into ».
struct DictionaryTabStrip<Trailing: View>: View {
    let dictionaries: [DictionaryInfo]
    @Binding var selected: String?
    @ViewBuilder var trailing: () -> Trailing

    private static func width(_ s: String) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width + 18
    }

    var body: some View {
        GeometryReader { geo in
            let items: [(id: String?, name: String)] = [(nil, "全部")] + dictionaries.map { ($0.id, $0.name) }
            let avail = geo.size.width - 24 - 60   // margins, » and the trailing button
            let (shown, hidden) = split(items, avail)
            HStack(spacing: 2) {
                ForEach(shown, id: \.name) { it in pill(it.name, selected == it.id) { selected = it.id } }
                if !hidden.isEmpty {
                    Menu {
                        ForEach(hidden, id: \.name) { it in
                            Button { selected = it.id } label: {
                                if selected == it.id { Label(it.name, systemImage: "checkmark") } else { Text(it.name) }
                            }
                        }
                    } label: { Text("»").font(.system(size: 13)) }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                Spacer(minLength: 4)
                trailing()
            }
            .padding(.horizontal, 12)
            .frame(height: geo.size.height)
        }
        .frame(height: 30)
    }

    private func split(_ items: [(id: String?, name: String)], _ avail: CGFloat) -> ([(id: String?, name: String)], [(id: String?, name: String)]) {
        var used: CGFloat = 0
        var shown: [(id: String?, name: String)] = []
        var hidden: [(id: String?, name: String)] = []
        for it in items {
            let w = Self.width(it.name)
            if hidden.isEmpty, used + w <= avail || shown.isEmpty { shown.append(it); used += w } else { hidden.append(it) }
        }
        // Keep the selected tab visible.
        if let i = hidden.firstIndex(where: { $0.id == selected }), let last = shown.indices.last, last > 0 {
            let sel = hidden.remove(at: i)
            hidden.insert(shown.remove(at: last), at: 0)
            shown.append(sel)
        }
        return (shown, hidden)
    }

    private func pill(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .lineLimit(1)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(on ? Color.primary.opacity(0.14) : .clear, in: Capsule())
                .contentShape(Rectangle())
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
    var zoom: Double = 1.0
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
        if abs(wv.pageZoom - zoom) > 0.001 { wv.pageZoom = zoom }
        let token = entries.map(\.id).joined(separator: "|") + "\(showTitles)\(emptyMessage)"
        guard token != context.coordinator.token else { return }
        context.coordinator.token = token
        let url = EntryWebViewFactory.pageURL(for: entries, showTitles: showTitles, panel: panel, emptyMessage: emptyMessage)
        wv.load(URLRequest(url: url))
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsModel
    @ObservedObject private var state = AppState.shared
    @State private var dicts: [DictionaryInfo] = []
    @State private var enabled: [String] = []

    var body: some View {
        TabView(selection: $state.settingsTab) {
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
            .tag("general")

            DictionarySettingsView()
            .tabItem { Label("词典", systemImage: "books.vertical") }
            .tag("dictionary")

            PlanSettingsView()
            .tabItem { Label("背单词", systemImage: "rectangle.stack") }
            .tag("review")
        }
    }
}
