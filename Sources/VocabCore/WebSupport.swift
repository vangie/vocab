import AVFoundation
import AppKit
import WebKit

/// In-memory documents served at vocab://entry/<key>.
public final class EntryDocumentStore: @unchecked Sendable {
    public static let shared = EntryDocumentStore()
    private var docs: [String: (Data, String)] = [:]
    private let lock = NSLock()

    @discardableResult
    public func register(_ html: String, mime: String = "application/xhtml+xml", key: String = UUID().uuidString) -> URL {
        lock.lock(); defer { lock.unlock() }
        docs[key] = (Data(html.utf8), mime)
        if docs.count > 400 { docs.removeAll(keepingCapacity: true); docs[key] = (Data(html.utf8), mime) }
        return URL(string: "\(EntryHTML.scheme)://entry/\(key)")!
    }

    func document(_ key: String) -> (Data, String)? {
        lock.lock(); defer { lock.unlock() }
        return docs[key]
    }
}

/// Serves entry documents and dictionary resources (vocab://file/<path>) from disk,
/// sidestepping file:// read-access restrictions in WKWebView.
public final class VocabSchemeHandler: NSObject, WKURLSchemeHandler {
    public override init() {}

    public func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var data: Data?
        var mime = "application/octet-stream"
        if url.host == "entry" {
            let key = url.lastPathComponent
            if let (d, m) = EntryDocumentStore.shared.document(key) { data = d; mime = m }
        } else if let file = EntryHTML.localFile(for: url), Self.isAllowed(file) {
            data = try? Data(contentsOf: file)
            mime = Self.mimeType(for: file.pathExtension)
        }
        guard let data else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)",
                                                  "Access-Control-Allow-Origin": "*"])!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    public func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    /// Only files inside a dictionary bundle may be served.
    static func isAllowed(_ file: URL) -> Bool {
        let p = file.resolvingSymlinksInPath().path
        if p.contains(".dictionary/") { return true }
        return DictionaryService.shared.knownBundlePaths().contains { p.hasPrefix($0) }
    }

    static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "css": return "text/css"
        case "js": return "text/javascript"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a", "aac": return "audio/mp4"
        case "html", "htm": return "text/html"
        default: return "application/octet-stream"
        }
    }
}

/// Plays dictionary audio natively.
public final class AudioPlayer: NSObject, @unchecked Sendable {
    public static let shared = AudioPlayer()
    private var player: AVAudioPlayer?
    private var last: (String, Date)?

    /// Play a file referenced by a vocab://file/… or file:// URL. Returns false if unplayable.
    @discardableResult
    public func play(urlString: String) -> Bool {
        if let (u, t) = last, u == urlString, Date().timeIntervalSince(t) < 0.4 { return true } // de-dupe mousedown+click
        last = (urlString, Date())
        guard let url = URL(string: urlString), let file = EntryHTML.localFile(for: url) else { return false }
        return play(file: file)
    }

    @discardableResult
    public func play(file: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else {
            NSLog("Vocab audio missing: %@", file.path)
            return false
        }
        do {
            let p = try AVAudioPlayer(contentsOf: file)
            p.prepareToPlay()
            player = p
            return p.play()
        } catch {
            NSLog("Vocab audio error: %@", error.localizedDescription)
            return false
        }
    }

    public var currentDuration: TimeInterval { player?.duration ?? 0 }
}

/// JavaScript injected into every frame.
public enum VocabScripts {
    /// Route every way dictionaries try to play sound to the native player.
    public static let audio = """
    (function(){
      if (window.__vocabAudio) return; window.__vocabAudio = true;
      function send(u){
        if (!u) return;
        try { var abs = new URL(u, document.baseURI).href;
              window.webkit.messageHandlers.vocabAudio.postMessage(abs); } catch(e) {}
      }
      HTMLMediaElement.prototype.play = function(){ send(this.getAttribute('src') || this.currentSrc || this.src); return Promise.resolve(); };
      window.Audio = function(src){ return { src: src, currentTime: 0, play: function(){ send(this.src); return Promise.resolve(); }, pause: function(){}, load: function(){} }; };
      document.addEventListener('click', function(e){
        var a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
        if (!a) return;
        var h = a.getAttribute('href') || '';
        var m = /Audio\\(\\s*["']([^"']+)["']\\s*\\)/.exec(h);
        if (h.indexOf('javascript:') === 0) { e.preventDefault(); e.stopPropagation(); if (m) send(m[1]); return; }
        if (h.indexOf('sound://') === 0) { e.preventDefault(); send(h.substring(8)); }
      }, true);
    })();
    """

    /// Size each iframe to its content.
    public static let autosize = """
    (function(){
      if (!window.frameElement) return;
      function fit(){ try { window.frameElement.style.height = Math.ceil(document.documentElement.scrollHeight) + 'px'; } catch(e) {} }
      document.addEventListener('DOMContentLoaded', fit);
      window.addEventListener('load', fit);
      try { new ResizeObserver(fit).observe(document.documentElement); } catch(e) {}
      setTimeout(fit, 300);
    })();
    """
}

/// Builds WKWebViews wired for dictionary content.
@MainActor
public final class EntryWebViewFactory: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    public var onLookup: ((String) -> Void)?
    public var onAudio: ((String, Bool) -> Void)?
    /// Scroll-spy: index of the dictionary section at the top of the view.
    public var onSection: ((Int) -> Void)?
    private let schemeHandler = VocabSchemeHandler()

    public override init() { super.init() }

    public func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: EntryHTML.scheme)
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: VocabScripts.audio, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        ucc.addUserScript(WKUserScript(source: VocabScripts.autosize, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        ucc.add(WeakMessageHandler(self), name: "vocabAudio")
        ucc.add(WeakMessageHandler(self), name: "vocabSection")
        config.userContentController = ucc
        config.mediaTypesRequiringUserActionForPlayback = []
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground")
        wv.navigationDelegate = self
        return wv
    }

    public func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "vocabSection" { if let i = (message.body as? NSNumber)?.intValue { onSection?(i) }; return }
        guard message.name == "vocabAudio", let s = message.body as? String else { return }
        let ok = AudioPlayer.shared.play(urlString: s)
        onAudio?(s, ok)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        switch url.scheme?.lowercased() {
        case EntryHTML.scheme, "about", "data":
            decisionHandler(.allow)
        case "x-dictionary", "dict":
            decisionHandler(.cancel)
            if let w = EntryHTML.lookupWord(fromLink: url) { onLookup?(w) }
        case "http", "https", "mailto":
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
        default:
            decisionHandler(.cancel)
        }
    }

    /// Register entries and build the outer page URL.
    public static func pageURL(for entries: [DictionaryEntry], showTitles: Bool, panel: Bool = false, emptyMessage: String) -> URL {
        var order: [String] = []
        var groups: [String: (String, [String])] = [:]
        for e in entries {
            let doc = EntryHTML.prepare(panel ? e.panelHTML : e.html, resourceDirectory: e.resourceDirectory,
                                        extraCSS: LongmanStyle.applies(to: e.dictionary.id) ? LongmanStyle.css : "",
                                        extraScript: LongmanStyle.applies(to: e.dictionary.id) ? LongmanStyle.script : "")
            // Our own (network) entries are served as XHTML only when they really are well-formed XML,
            // so a stray tag can never turn into WebKit's red XML-error page.
            let mime = e.dictionary.isNetwork && !EntryHTML.isWellFormedXML(doc) ? "text/html" : "application/xhtml+xml"
            let u = EntryDocumentStore.shared.register(doc, mime: mime).absoluteString
            if groups[e.dictionary.id] == nil { order.append(e.dictionary.id); groups[e.dictionary.id] = (e.dictionary.displayName, []) }
            groups[e.dictionary.id]!.1.append(u)
        }
        let sections = order.map { EntryHTML.Section(title: groups[$0]!.0, frameURLs: groups[$0]!.1) }
        let page = EntryHTML.page(sections: sections, showTitles: showTitles, emptyMessage: emptyMessage)
        return EntryDocumentStore.shared.register(page, mime: "text/html")
    }
}

/// Avoids the retain cycle WKUserContentController creates with its handlers.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}
