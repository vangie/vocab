import Foundation

/// Helpers that turn DictionaryServices XHTML into something WKWebView can render
/// with working relative resources, dark mode and native audio.
public enum EntryHTML {
    public static let scheme = "vocab"
    public static let containerDictionaries = "/Library/Containers/com.apple.Dictionary/Data/Library/Dictionaries/"

    /// Extract `<base href="…">`, map Dictionary.app's sandbox container path back to
    /// ~/Library/Dictionaries, and return the folder relative URLs resolve against.
    public static func resourceDirectory(fromHTML html: String, bundleURL: URL?) -> URL? {
        if let href = baseHref(in: html), let url = URL(string: href), url.isFileURL {
            return mapContainerPath(url).deletingLastPathComponent()
        }
        guard let bundleURL else { return nil }
        let res = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        return FileManager.default.fileExists(atPath: res.path) ? res : bundleURL.appendingPathComponent("Contents", isDirectory: true)
    }

    public static func baseHref(in html: String) -> String? {
        guard let r = html.range(of: #"<base\s+href="([^"]+)""#, options: .regularExpression) else { return nil }
        let tag = String(html[r])
        guard let q1 = tag.range(of: "href=\"") else { return nil }
        let rest = tag[q1.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }

    public static func mapContainerPath(_ url: URL, home: String = NSHomeDirectory()) -> URL {
        let p = url.path
        guard let r = p.range(of: containerDictionaries) else { return url }
        return URL(fileURLWithPath: home + "/Library/Dictionaries/" + p[r.upperBound...])
    }

    /// `vocab://file/<absolute path>/` for a resource folder.
    public static func resourceBase(for dir: URL) -> String {
        var path = dir.path
        if !path.hasSuffix("/") { path += "/" }
        let enc = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "\(scheme)://file\(enc)"
    }

    /// Map a `vocab://file/...` (or file://) URL back to a local file URL.
    public static func localFile(for url: URL) -> URL? {
        if url.isFileURL { return mapContainerPath(url) }
        guard url.scheme == scheme, url.host == "file" else { return nil }
        return mapContainerPath(URL(fileURLWithPath: url.path))
    }

    /// CSS added to every entry document.
    public static let injectedCSS = """
    :root { color-scheme: light dark; }
    html, body { background: transparent !important; margin: 0; }
    body { padding: 2px 4px; font-family: -apple-system, "PingFang SC", sans-serif; }
    @media (prefers-color-scheme: dark) {
      html:not(.apple_appearance-incompliant) body { color: #e5e5e7; }
      html.apple_appearance-incompliant body { color: #111; background: transparent; }
      html.apple_appearance-incompliant body { filter: invert(0.88) hue-rotate(180deg); }
      html.apple_appearance-incompliant img { filter: invert(1) hue-rotate(180deg); }
    }
    .v-spk { cursor: pointer !important; transition: opacity .12s, color .12s; }
    .v-spk:hover { opacity: 1 !important; color: -apple-system-control-accent !important; filter: drop-shadow(0 0 1px -apple-system-control-accent); }
    img.v-spk:hover { opacity: .7 !important; }
    """

    /// Marks every audio trigger (Longman BrE/AmE, OALD, example speakers…) with
    /// `v-spk` (pointer + hover highlight) and a Chinese tooltip.
    public static let speakerScript = """
    (function(){
    function kind(el){
      var s=((el.getAttribute('class')||'')+' '+(el.getAttribute('href')||'')+' '+(el.getAttribute('onmousedown')||'')+' '+(el.getAttribute('onclick')||'')+' '+(el.getAttribute('src')||'')+' '+(el.getAttribute('title')||'')).toLowerCase();
      for(var a=el.parentNode;a&&a.getAttribute;a=a.parentNode){var c=(a.getAttribute('class')||'').toLowerCase();if(/exa|example|(^|\\s)(x|x-g|eg|sentence)(\\s|$)/.test(c))return '播放例句';}
      if(/exa|example|sentence/.test(s))return '播放例句';
      if(/brefile|\\bbre\\b|_gb|\\bgb\\b|uk_|_uk|british|pron-uk|\\buk\\b/.test(s))return '播放英音';
      if(/amefile|\\bame\\b|_us|\\bus\\b|us_|american|pron-us/.test(s))return '播放美音';
      return '播放读音';
    }
    function mark(){
      var q='a.speaker,[class*="speaker"],[class*="sound"],[class*="audio"],a[href*=".mp3"],a[href*="Audio("],[onmousedown*="Audio"],[onclick*="Audio"],[onclick*=".mp3"],img[onmousedown],audio';
      var els=document.querySelectorAll(q);
      for(var i=0;i<els.length;i++){var e=els[i];if(e.querySelector&&e.querySelector('a.speaker,[onmousedown*="Audio"],a[href*=".mp3"]'))continue;
        var c=e.getAttribute('class')||'';if((' '+c+' ').indexOf(' v-spk ')<0)e.setAttribute('class',(c+' v-spk').trim());
        e.setAttribute('title',kind(e));}
    }
    if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',mark);else mark();
    })();
    """

    public static func isWellFormedXML(_ s: String) -> Bool { XMLParser(data: Data(s.utf8)).parse() }

    /// Prepare a full entry document: point <base> at our scheme, inject CSS.
    public static func prepare(_ html: String, resourceDirectory: URL?, extraCSS: String = "", extraScript: String = "") -> String {
        var s = html
        // DictionaryServices output declares only xmlns:d; without the XHTML default
        // namespace WebKit's XML parser treats <style>, <a onmousedown> etc. as unknown elements.
        if let r = s.range(of: "<html"), !s.contains("xmlns=\"http://www.w3.org/1999/xhtml\"") {
            s.replaceSubrange(r, with: "<html xmlns=\"http://www.w3.org/1999/xhtml\"")
        }
        let base = resourceDirectory.map { "<base href=\"\(resourceBase(for: $0))\" />" } ?? ""
        if let r = s.range(of: #"<base\s+href="[^"]*"\s*/?>"#, options: .regularExpression) {
            s.replaceSubrange(r, with: base)
        } else if let r = s.range(of: "<head>") {
            s.replaceSubrange(r, with: "<head>" + base)
        } else if let r = s.range(of: "<head/>") {
            s.replaceSubrange(r, with: "<head>" + base + "</head>")
        }
        let style = "<style type=\"text/css\">/*<![CDATA[*/\n\(injectedCSS)\n\(extraCSS)\n/*]]>*/</style>"
        if let r = s.range(of: "</head>", options: .backwards) {
            let script = "<script type=\"text/javascript\">//<![CDATA[\n\(speakerScript)\n\(extraScript)\n//]]></script>"
            s.replaceSubrange(r, with: style + script + "</head>")
        }
        return s
    }

    /// Audio files referenced by an entry, in both forms we know:
    /// `javascript:new Audio("x.mp3").play()` and `<audio src="x.mp3">`.
    public static func audioReferences(in html: String) -> [String] {
        var out: [String] = []
        let patterns = [#"Audio\((?:&quot;|")([^"&]+?\.(?:mp3|wav|aac|m4a|spx))(?:&quot;|")\)"#,
                        #"<audio[^>]*\ssrc="([^"]+)""#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let ns = html as NSString
            for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let v = ns.substring(with: m.range(at: 1))
                if !out.contains(v) { out.append(v) }
            }
        }
        return out
    }

    /// Word from an `x-dictionary:` / `dict:` link, e.g. `x-dictionary:d:borrow#a` → "borrow".
    public static func lookupWord(fromLink url: URL) -> String? {
        let raw = url.absoluteString
        var rest: Substring
        if raw.hasPrefix("x-dictionary:") { rest = raw.dropFirst("x-dictionary:".count) }
        else if raw.hasPrefix("dict://") { rest = raw.dropFirst("dict://".count) }
        else if raw.hasPrefix("dict:") { rest = raw.dropFirst("dict:".count) }
        else { return nil }
        if rest.hasPrefix("d:") { rest = rest.dropFirst(2) }
        else if rest.hasPrefix("r:") { return nil }
        if let h = rest.firstIndex(of: "#") { rest = rest[..<h] }
        if let c = rest.firstIndex(of: ":") { rest = rest[..<c] }
        let w = String(rest).removingPercentEncoding ?? String(rest)
        return w.isEmpty ? nil : w
    }

    public struct Section {
        public let title: String
        public let frameURLs: [String]
        public init(title: String, frameURLs: [String]) { self.title = title; self.frameURLs = frameURLs }
    }

    /// The outer page: one titled section per dictionary, each record in its own iframe
    /// so every dictionary keeps its own <base> and stylesheet.
    /// Scroll-spy: reports the index of the section at the top of the viewport (vocabSection),
    /// and window.vocabScrollTo(i) smooth-scrolls to a section.
    static let spyScript = """
    (function(){
      var last = -1;
      function report(){
        var secs = document.querySelectorAll('section'); var cur = 0;
        for (var k = 0; k < secs.length; k++) { if (secs[k].getBoundingClientRect().top <= 48) cur = k; }
        if ((window.innerHeight + window.scrollY) >= document.body.scrollHeight - 2 && secs.length) {
          var lastTop = secs[secs.length-1].getBoundingClientRect().top; if (lastTop < window.innerHeight) cur = Math.max(cur, secs.length-1);
        }
        if (cur !== last) { last = cur; try { webkit.messageHandlers.vocabSection.postMessage(cur); } catch(e){} }
      }
      window.addEventListener('scroll', report, {passive:true});
      window.vocabScrollTo = function(i){ var s = document.getElementById('vsec-'+i); if (!s) return;
        window.scrollTo({top: i === 0 ? 0 : s.getBoundingClientRect().top + window.scrollY - 4, behavior: 'smooth'}); };
      report();
    })();
    """

    public static func page(sections: [Section], showTitles: Bool, emptyMessage: String = "") -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var body = ""
        if sections.isEmpty && !emptyMessage.isEmpty {
            body = "<div class=\"empty\">\(esc(emptyMessage))</div>"
        }
        for (i, s) in sections.enumerated() {
            body += "<section id=\"vsec-\(i)\" data-i=\"\(i)\">"
            if showTitles { body += "<h2 class=\"dict\"><span>\(esc(s.title))</span></h2>" }
            for u in s.frameURLs { body += "<iframe src=\"\(u)\" scrolling=\"no\"></iframe>" }
            body += "</section>"
        }
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark; }
        html, body { background: transparent; margin: 0; font-family: -apple-system, "PingFang SC", sans-serif; }
        body { padding: 8px 22px 30px; }
        iframe { display: block; width: 100%; border: 0; height: 40px; overflow: hidden; }
        /* Section titles: secondary-label contrast (≈7:1 on the popup's vibrancy and the window). */
        h2.dict { display: flex; align-items: center; gap: 12px; font-weight: 500; font-size: 16px;
                  color: #555558; margin: 22px 0 6px; }
        h2.dict::before, h2.dict::after { content: ""; flex: 1; border-top: 1px solid rgba(0,0,0,.22); }
        @media (prefers-color-scheme: dark) {
          h2.dict { color: #bdbdc2; }
          h2.dict::before, h2.dict::after { border-top-color: rgba(255,255,255,.26); }
        }
        .empty { color: #8a8a8e; text-align: center; margin-top: 80px; font-size: 15px; }
        section:first-child h2.dict { margin-top: 6px; }
        </style></head><body>\(body)<script>\(spyScript)</script></body></html>
        """
    }
}
