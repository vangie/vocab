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

/// Settings › 词典: reorderable list with checkboxes and a language column, and the selected
/// dictionary's own preferences (its DCSDictionaryPrefsHTML) or description below — like Dictionary.app.
struct DictionarySettingsView: View {
    @State private var dicts: [DictionaryInfo] = []
    @State private var enabled: [String] = []
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("将参考源拖移成你喜欢的顺序：").font(.system(size: 12))
            List(selection: $selection) {
                ForEach(dicts) { d in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(get: { enabled.contains(d.id) }, set: { setEnabled(d.id, $0) }))
                            .toggleStyle(.checkbox).labelsHidden()
                        Text(d.name).lineLimit(1)
                        Spacer()
                        Text(DictionaryOrder.languageLabel(d)).foregroundStyle(.secondary).font(.system(size: 11)).lineLimit(1)
                    }
                    .tag(d.id)
                }
                .onMove { from, to in
                    dicts.move(fromOffsets: from, toOffset: to)
                    persist()
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 170)
            HStack {
                Button("恢复为系统词典设置") {
                    UserDefaults.standard.removeObject(forKey: DictionarySelection.key)
                    UserDefaults.standard.removeObject(forKey: DictionaryOrder.key)
                    reload()
                }
                Spacer()
            }
            Divider()
            if let id = selection, let d = dicts.first(where: { $0.id == id }) {
                DictionaryDetailView(dictionary: d).id(d.id)
            } else {
                Text("选择一个词典查看它的说明和设置").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
        .onAppear(perform: reload)
    }

    private func reload() {
        dicts = DictionaryOrder.all()
        enabled = DictionarySelection.enabled().map(\.id)
        if selection == nil { selection = dicts.first?.id }
    }

    private func setEnabled(_ id: String, _ on: Bool) {
        if on { if !enabled.contains(id) { enabled.append(id) } } else { enabled.removeAll { $0 == id } }
        persist()
    }

    /// Save the order, and the enabled list in that order (lookups follow it).
    private func persist() {
        UserDefaults.standard.set(dicts.map(\.id), forKey: DictionaryOrder.key)
        UserDefaults.standard.set(dicts.map(\.id).filter { enabled.contains($0) }, forKey: DictionarySelection.key)
        NotificationCenter.default.post(name: .vocabDictionaryPrefsChanged, object: nil)
    }
}

struct DictionaryDetailView: View {
    let dictionary: DictionaryInfo

    var body: some View {
        let p = DictionaryPrefs(bundleURL: dictionary.bundleURL)
        if let p, p.prefsHTML != nil {
            VStack(alignment: .leading, spacing: 4) {
                DictionaryPrefsWebView(prefs: p)
                HStack {
                    Text("这些设置只影响「生词」，不会改动系统「词典」App。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复为「词典」App 的设置") {
                        p.reset()
                        NotificationCenter.default.post(name: .vocabDictionaryPrefsChanged, object: p.bundleID)
                    }.controlSize(.small)
                }
            }
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
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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
          st.textContent = ':root{color-scheme:light dark} body{font:12px -apple-system,sans-serif;background:transparent;margin:6px 2px} a{color:-apple-system-control-accent}';
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
