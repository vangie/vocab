import AppKit
import SwiftUI
import VocabCore
import WebKit

extension Notification.Name {
    static let vocabDictionaryPrefsChanged = Notification.Name("VocabDictionaryPrefsChanged")
}

/// Order of all dictionaries in Vocab (enabled ones first by default).
enum DictionaryOrder {
    static let key = "dictionaryOrder"

    static func all() -> [DictionaryInfo] {
        let avail = DictionaryService.shared.availableDictionaries()
        let saved = UserDefaults.standard.array(forKey: key) as? [String] ?? []
        let enabled = DictionarySelection.enabled().map(\.id)
        var ids = saved.filter { id in avail.contains { $0.id == id } }
        for id in enabled where !ids.contains(id) { ids.append(id) }
        for d in avail where !ids.contains(d.id) { ids.append(d.id) }
        return ids.compactMap { id in avail.first { $0.id == id } }
    }

    static func languageLabel(_ d: DictionaryInfo) -> String {
        let langs = DictionaryPrefs(bundleURL: d.bundleURL)?.languages ?? []
        let names = langs.map { Locale.current.localizedString(forIdentifier: $0) ?? $0 }
        return names.joined(separator: " – ")
    }
}

/// Settings › 词典, laid out like Dictionary.app: label, bordered AppKit table (accent selection,
/// alternating rows, checkbox + name, language right-aligned), and the selected dictionary's
/// preferences in a bordered box below. Resets live in the table's context menu.
struct DictionarySettingsView: View {
    @State private var dicts: [DictionaryInfo] = []
    @State private var enabled: [String] = []
    @State private var selection: String?

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 8) {
                Text("将参考源拖移成你喜欢的顺序：").font(.system(size: 13))
                DictionaryTable(dicts: $dicts, enabled: $enabled, selection: $selection,
                                onChange: persist, onResetOrder: resetOrder, onResetPrefs: resetPrefs)
                    .frame(height: max(150, (geo.size.height - 40) * 0.4))
                Group {
                    if let id = selection, let d = dicts.first(where: { $0.id == id }) {
                        DictionaryDetailView(dictionary: d).id(d.id)
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                .overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            }
            .padding(20)
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        dicts = DictionaryOrder.all()
        enabled = DictionarySelection.enabled().map(\.id)
        if selection == nil { selection = dicts.first?.id }
    }

    private func resetOrder() {
        UserDefaults.standard.removeObject(forKey: DictionarySelection.key)
        UserDefaults.standard.removeObject(forKey: DictionaryOrder.key)
        reload()
        NotificationCenter.default.post(name: .vocabDictionaryPrefsChanged, object: nil)
    }

    private func resetPrefs(_ id: String) {
        guard let d = dicts.first(where: { $0.id == id }), let p = DictionaryPrefs(bundleURL: d.bundleURL) else { return }
        p.reset()
        let keep = selection; selection = nil
        DispatchQueue.main.async { selection = keep }   // reload the prefs page
        NotificationCenter.default.post(name: .vocabDictionaryPrefsChanged, object: p.bundleID)
    }

    /// Save the order, and the enabled list in that order (lookups follow it).
    private func persist() {
        UserDefaults.standard.set(dicts.map(\.id), forKey: DictionaryOrder.key)
        UserDefaults.standard.set(dicts.map(\.id).filter { enabled.contains($0) }, forKey: DictionarySelection.key)
        NotificationCenter.default.post(name: .vocabDictionaryPrefsChanged, object: nil)
    }
}

/// NSTableView-backed list so selection, row height, stripes and drag-reorder match AppKit exactly.
struct DictionaryTable: NSViewRepresentable {
    @Binding var dicts: [DictionaryInfo]
    @Binding var enabled: [String]
    @Binding var selection: String?
    var onChange: () -> Void
    var onResetOrder: () -> Void
    var onResetPrefs: (String) -> Void

    static let dragType = NSPasteboard.PasteboardType("io.github.vangie.vocab.dictionary-row")

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil
        table.usesAlternatingRowBackgroundColors = true
        table.style = .plain
        table.rowSizeStyle = .custom
        table.rowHeight = 17
        table.intercellSpacing = NSSize(width: 3, height: 2)
        table.allowsEmptySelection = true
        table.focusRingType = .none
        let name = NSTableColumn(identifier: .init("name")); name.resizingMask = .autoresizingMask
        let lang = NSTableColumn(identifier: .init("lang")); lang.width = 170; lang.resizingMask = []
        table.addTableColumn(name); table.addTableColumn(lang)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.registerForDraggedTypes([Self.dragType])
        table.draggingDestinationFeedbackStyle = .gap
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let table = c.table else { return }
        if c.shownIDs != dicts.map(\.id) || c.shownEnabled != enabled {
            c.shownIDs = dicts.map(\.id); c.shownEnabled = enabled
            table.reloadData()
        }
        let row = selection.flatMap { id in dicts.firstIndex { $0.id == id } } ?? -1
        if table.selectedRow != row {
            c.syncing = true
            if row >= 0 { table.selectRowIndexes([row], byExtendingSelection: false) } else { table.deselectAll(nil) }
            c.syncing = false
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: DictionaryTable
        weak var table: NSTableView?
        var shownIDs: [String] = []
        var shownEnabled: [String] = []
        var syncing = false
        init(_ p: DictionaryTable) { parent = p }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.dicts.count }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            let d = parent.dicts[row]
            if column?.identifier.rawValue == "lang" {
                let t = NSTextField(labelWithString: DictionaryOrder.languageLabel(d))
                t.font = .systemFont(ofSize: 13)
                t.textColor = .secondaryLabelColor
                t.alignment = .right
                t.lineBreakMode = .byTruncatingTail
                return t
            }
            let b = NSButton(checkboxWithTitle: d.name, target: self, action: #selector(toggle(_:)))
            b.font = .systemFont(ofSize: 13)
            b.tag = row
            b.state = parent.enabled.contains(d.id) ? .on : .off
            b.lineBreakMode = .byTruncatingTail
            return b
        }

        @objc func toggle(_ b: NSButton) {
            guard b.tag < parent.dicts.count else { return }
            let id = parent.dicts[b.tag].id
            if b.state == .on { if !parent.enabled.contains(id) { parent.enabled.append(id) } }
            else { parent.enabled.removeAll { $0 == id } }
            shownEnabled = parent.enabled
            parent.onChange()
        }

        func tableViewSelectionDidChange(_ n: Notification) {
            guard !syncing, let t = table else { return }
            parent.selection = t.selectedRow >= 0 ? parent.dicts[t.selectedRow].id : nil
        }

        // Drag to reorder.
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            let item = NSPasteboardItem(); item.setString(String(row), forType: DictionaryTable.dragType); return item
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
            if op == .on { tableView.setDropRow(row, dropOperation: .above) }
            return .move
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            guard let s = info.draggingPasteboard.pasteboardItems?.first?.string(forType: DictionaryTable.dragType),
                  let from = Int(s) else { return false }
            var list = parent.dicts
            let item = list.remove(at: from)
            let to = from < row ? row - 1 : row
            list.insert(item, at: to)
            parent.dicts = list
            shownIDs = list.map(\.id)
            tableView.reloadData()
            tableView.selectRowIndexes([to], byExtendingSelection: false)
            parent.onChange()
            return true
        }

        // Right-click menu with the resets (kept out of the visible layout, like native).
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let order = NSMenuItem(title: "恢复默认顺序", action: #selector(resetOrder), keyEquivalent: "")
            order.target = self
            menu.addItem(order)
            if let t = table, t.clickedRow >= 0 {
                let d = parent.dicts[t.clickedRow]
                if DictionaryPrefs(bundleURL: d.bundleURL)?.prefsHTML != nil {
                    let it = NSMenuItem(title: "恢复此词典默认设置", action: #selector(resetPrefs(_:)), keyEquivalent: "")
                    it.target = self; it.representedObject = d.id
                    menu.addItem(it)
                }
            }
        }
        @objc func resetOrder() { parent.onResetOrder() }
        @objc func resetPrefs(_ i: NSMenuItem) { if let id = i.representedObject as? String { parent.onResetPrefs(id) } }
    }
}

struct DictionaryDetailView: View {
    let dictionary: DictionaryInfo

    var body: some View {
        let p = DictionaryPrefs(bundleURL: dictionary.bundleURL)
        if let p, p.prefsHTML != nil {
            DictionaryPrefsWebView(prefs: p)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(dictionary.name).font(.headline)
                    if let c = p?.copyright { Text(c) }
                    if let m = p?.manufacturer { Text("制作：\(m)").foregroundStyle(.secondary) }
                    if let v = p?.version { Text("版本：\(v)").foregroundStyle(.secondary) }
                    let langs = DictionaryOrder.languageLabel(dictionary)
                    if !langs.isEmpty { Text("语言：\(langs)").foregroundStyle(.secondary) }
                    Text("这个词典没有可调整的显示选项。").foregroundStyle(.secondary).padding(.top, 4)
                }
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
        }
    }
}

/// Renders the dictionary's own preferences HTML and maps its form to preference keys the
/// way Dictionary.app does: checkbox name=N value=V ↔ key "N-V" = "1"/"0"; radio, select,
/// text and hidden inputs ↔ key N = value.
struct DictionaryPrefsWebView: NSViewRepresentable {
    let prefs: DictionaryPrefs

    func makeCoordinator() -> Coordinator { Coordinator(prefs: prefs) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let uc = WKUserContentController()
        uc.add(context.coordinator, name: "vocabPrefs")
        let values = (try? JSONSerialization.data(withJSONObject: prefs.effective())).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let copyright = (try? JSONSerialization.data(withJSONObject: [prefs.copyright ?? ""])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        let js = """
        (function(){
          var prefs = \(values);
          var st = document.createElement('style');
          st.textContent = ':root{color-scheme:light dark} body{font:13px -apple-system,system-ui,sans-serif;line-height:1.35;background:transparent;margin:10px;color:-apple-system-label} hr{border:0;border-top:1px solid -apple-system-separator;margin:8px 0} a{color:-apple-system-link} input,select{-webkit-appearance:auto!important;appearance:auto!important;accent-color:-apple-system-control-accent;font:inherit;margin:3px 5px 3px 0;vertical-align:-2px} input[type=checkbox],input[type=radio]{width:14px;height:14px}';
          document.head && document.head.appendChild(st);
          var c = document.getElementById('copyright'); if (c && !c.textContent.trim()) c.textContent = \(copyright)[0];
          var inputs = document.querySelectorAll('input, select');
          inputs.forEach(function(el){
            var n = el.name; if (!n) return;
            if (el.type === 'checkbox') el.checked = prefs[n + '-' + el.value] === '1';
            else if (el.type === 'radio') el.checked = prefs[n] === el.value;
            else if (prefs[n] !== undefined) el.value = prefs[n];
          });
          function collect(){
            var out = {};
            inputs.forEach(function(el){
              var n = el.name; if (!n) return;
              if (el.type === 'checkbox') out[n + '-' + el.value] = el.checked ? '1' : '0';
              else if (el.type === 'radio') { if (el.checked) out[n] = el.value; }
              else out[n] = el.value;
            });
            window.webkit.messageHandlers.vocabPrefs.postMessage(out);
          }
          inputs.forEach(function(el){ el.addEventListener('change', collect); });
        })();
        """
        uc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        cfg.userContentController = uc
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.setValue(false, forKey: "drawsBackground")
        wv.navigationDelegate = context.coordinator
        if let html = prefs.prefsHTML {
            wv.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let prefs: DictionaryPrefs
        init(prefs: DictionaryPrefs) { self.prefs = prefs }

        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let d = message.body as? [String: Any] else { return }
            var values = prefs.effective()
            for (k, v) in d { values[k] = "\(v)" }
            prefs.save(values)
            VocabLog.log("dictionary prefs \(prefs.bundleID): overrides=\(prefs.vocabOverrides())")
            NotificationCenter.default.post(name: .vocabDictionaryPrefsChanged, object: prefs.bundleID)
        }

        // Links in the prefs page (About, feedback) open outside, never inside Settings.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
