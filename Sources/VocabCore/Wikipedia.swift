import Foundation

public extension DictionaryInfo {
    /// Dictionary.app's Wikipedia (a DCS dictionary we never search through DCS; see `WikipediaClient`).
    var isWikipedia: Bool { id.localizedCaseInsensitiveContains("wikipedia") }
    /// Sources fetched over the network by Vocab itself (Wikipedia, 百度百科). A DCS call to Wikipedia
    /// blocks for seconds, so these are never searched through DCS.
    var isNetwork: Bool { isWikipedia || id == BaikeClient.id }
}

/// Shared look for Vocab's own network entries (Wikipedia, 百度百科): system font and label colours,
/// light and dark.
public enum NetEntryStyle {
    /// Quick-lookup popup variant: small picture, floated right so the text wraps around it.
    public static func panel(_ html: String) -> String {
        let css = "<style>.net .thumb { max-width: 72px; max-height: 72px; margin: 2px 0 6px 10px; border-radius: 5px; }</style>"
        if let r = html.range(of: "</head>") { return html.replacingCharacters(in: r, with: css + "</head>") }
        return css + html
    }

    public static let css = """
    :root { color-scheme: light dark; --l: rgba(0,0,0,.85); --s: rgba(0,0,0,.55); --t: rgba(0,0,0,.38); --f: rgba(0,0,0,.045); --sep: rgba(0,0,0,.1); }
    @media (prefers-color-scheme: dark) { :root { --l: rgba(255,255,255,.86); --s: rgba(255,255,255,.55); --t: rgba(255,255,255,.36); --f: rgba(255,255,255,.06); --sep: rgba(255,255,255,.12); } }
    .net { font: 14px/1.55 -apple-system, "PingFang SC", sans-serif; color: var(--l); }
    .net h2 { font-size: 22px; font-weight: 600; color: -apple-system-control-accent; margin: 2px 0 2px; }
    .net .desc { color: var(--s); margin: 0 0 8px; font-size: 13px; }
    .net p { margin: 6px 0; }
    .net .thumb { float: right; max-width: 140px; max-height: 140px; margin: 2px 0 8px 14px; border-radius: 6px; }
    @media (prefers-color-scheme: dark) { .net .thumb { background: #f2f2f2; padding: 4px; } }
    .net .langs { display: inline-flex; gap: 2px; padding: 2px; background: var(--f); border-radius: 7px; margin: 0 0 8px; }
    .net .langs a { font-size: 12px; color: var(--s); text-decoration: none; padding: 2px 10px; border-radius: 5px; }
    .net .langs a.on { background: rgba(127,127,127,.22); color: var(--l); font-weight: 500; }
    .net .note { color: var(--s); font-size: 12px; margin: 0 0 6px; }
    .net table.card { border-collapse: collapse; margin: 10px 0; font-size: 13px; background: var(--f); border-radius: 8px; }
    .net table.card td { padding: 3px 10px; vertical-align: top; }
    .net table.card td.k { color: var(--s); white-space: nowrap; }
    .net .toc { color: var(--s); font-size: 13px; margin: 10px 0; }
    .net .toc b { font-size: 11px; font-weight: 600; letter-spacing: .04em; }
    .net .more { margin-top: 10px; font-size: 13px; }
    .net .more a { color: -apple-system-control-accent; text-decoration: none; }
    .net .clear { clear: both; }
    """
    public static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
    /// Well-formed XHTML document around `body`.
    public static func document(_ body: String) -> String {
        "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><meta charset=\"utf-8\"/><style type=\"text/css\">/*<![CDATA[*/\n\(css)\n/*]]>*/</style></head><body><div class=\"net\">\(body)</div></body></html>"
    }
}

/// Wikipedia summaries in the languages ticked in Settings › 词典 (default 中文 + English, 中文 first),
/// matched across languages through the langlinks API. Chinese uses the zh-cn (simplified) variant.
/// URLSession's default configuration uses the system proxy settings (HTTP/HTTPS/SOCKS/PAC).
public enum WikipediaClient {
    public struct Article: Sendable, Equatable {
        public var lang: String, title: String, html: String, text: String
        /// Ticked languages that have this article, in Settings order.
        public var available: [String]
    }
    public enum Outcome: Sendable { case found(Article), notFound, failed }

    // MARK: languages

    public static let supported: [(code: String, name: String)] = [
        ("zh", "中文"), ("en", "English"), ("ja", "日本語"), ("ko", "한국어"), ("fr", "Français"),
        ("de", "Deutsch"), ("es", "Español"), ("ru", "Русский"), ("it", "Italiano"), ("pt", "Português"),
    ]
    public static func name(_ code: String) -> String { supported.first { $0.code == code }?.name ?? code }
    public static let languagesKey = "wikipediaLanguages"
    public static let defaultLanguages = ["zh", "en"]

    /// Ticked languages, in display order (first = default).
    public static func languages(_ d: UserDefaults = .standard) -> [String] {
        let v = (d.array(forKey: languagesKey) as? [String] ?? defaultLanguages).filter { c in supported.contains { $0.code == c } }
        return v.isEmpty ? defaultLanguages : v
    }
    public static func setLanguages(_ v: [String], _ d: UserDefaults = .standard) {
        d.set(supported.map(\.code).filter { v.contains($0) }, forKey: languagesKey)
    }

    // MARK: network

    public static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 6
        c.timeoutIntervalForResource = 8
        c.requestCachePolicy = .returnCacheDataElseLoad
        c.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 0)
        return URLSession(configuration: c)
    }()

    /// Language the typed term most likely belongs to.
    public static func language(for term: String) -> String {
        if term.range(of: #"[\p{Hiragana}\p{Katakana}]"#, options: .regularExpression) != nil { return "ja" }
        if term.range(of: #"\p{Hangul}"#, options: .regularExpression) != nil { return "ko" }
        if term.range(of: #"\p{Cyrillic}"#, options: .regularExpression) != nil { return "ru" }
        return term.range(of: #"\p{Han}"#, options: .regularExpression) != nil ? "zh" : "en"
    }

    static func titlePath(_ t: String) -> String? {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "_")
        guard !s.isEmpty else { return nil }
        return s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#")))
    }

    public static func summaryURL(_ term: String, lang: String) -> URL? {
        guard let e = titlePath(term) else { return nil }
        return URL(string: "https://\(lang).wikipedia.org/api/rest_v1/page/summary/\(e)?redirect=true")
    }

    public static func langlinksURL(_ title: String, lang: String) -> URL? {
        var c = URLComponents(string: "https://\(lang).wikipedia.org/w/api.php")!
        c.queryItems = [.init(name: "action", value: "query"), .init(name: "prop", value: "langlinks"), .init(name: "titles", value: title),
                        .init(name: "redirects", value: "1"), .init(name: "lllimit", value: "max"),
                        .init(name: "format", value: "json"), .init(name: "formatversion", value: "2")]
        return c.url
    }

    static func request(_ url: URL, lang: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("Vocab/1.0 (macOS dictionary app)", forHTTPHeaderField: "User-Agent")
        if lang == "zh" { r.setValue("zh-cn", forHTTPHeaderField: "Accept-Language") }   // simplified variant
        return r
    }

    struct Summary { var title: String, description: String?, extract: String, url: String?, thumb: String? }
    enum Fetched { case ok(Summary), notFound, failed }

    static func summary(_ title: String, lang: String) async -> Fetched {
        guard let url = summaryURL(title, lang: lang) else { return .notFound }
        do {
            let (data, resp) = try await session.data(for: request(url, lang: lang))
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { return .notFound }
            guard code == 200, let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failed }
            let extract = j["extract"] as? String ?? ""
            if extract.isEmpty { return .notFound }
            let link = ((j["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String
            let thumb = (j["thumbnail"] as? [String: Any])?["source"] as? String
            return .ok(Summary(title: j["title"] as? String ?? title, description: j["description"] as? String,
                               extract: extract, url: link, thumb: thumb))
        } catch { return .failed }
    }

    /// Canonical title in `lang` plus its titles in other languages; nil when the page doesn't exist.
    static func langlinks(_ title: String, lang: String) async -> (title: String, links: [String: String])?? {
        guard let url = langlinksURL(title, lang: lang) else { return .some(nil) }
        do {
            let (data, resp) = try await session.data(for: request(url, lang: lang))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return .some(parseLanglinks(data))
        } catch { return nil }
    }

    public static func parseLanglinks(_ data: Data) -> (title: String, links: [String: String])? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let page = ((j["query"] as? [String: Any])?["pages"] as? [[String: Any]])?.first,
              page["missing"] == nil, page["invalid"] == nil, let t = page["title"] as? String else { return nil }
        var links: [String: String] = [:]
        for l in page["langlinks"] as? [[String: Any]] ?? [] {
            if let c = l["lang"] as? String, let lt = l["title"] as? String { links[c] = lt }
        }
        return (t, links)
    }

    /// Order in which to try languages: the preferred one, then the ticked ones in order.
    public static func order(preferred: String?, ticked: [String]) -> [String] {
        var out: [String] = []
        if let p = preferred, ticked.contains(p) { out.append(p) }
        for l in ticked where !out.contains(l) { out.append(l) }
        return out
    }

    /// The article in `preferred` (or the first ticked language that has it).
    public static func fetch(_ term: String, preferred: String? = nil, languages ticked: [String]? = nil) async -> Outcome {
        let ticked = ticked ?? languages()
        let order = order(preferred: preferred, ticked: ticked)
        // Find the article: in the term's own language first, then in each ticked language.
        var titles: [String: String] = [:]
        var anyFailed = false
        var origins = [language(for: term)]
        for l in ticked where !origins.contains(l) { origins.append(l) }
        for src in origins {
            switch await langlinks(term, lang: src) {
            case nil: anyFailed = true; continue
            case .some(nil): continue
            case let .some(.some(found)):
                titles = found.links; titles[src] = found.title
            }
            break
        }
        if titles.isEmpty { return anyFailed ? .failed : .notFound }
        let available = ticked.filter { titles[$0] != nil }
        for lang in order {
            guard let t = titles[lang] else { continue }
            switch await summary(t, lang: lang) {
            case .ok(let s):
                return .found(Article(lang: lang, title: s.title, html: page(s, lang: lang, available: available),
                                      text: s.extract, available: available))
            case .notFound: continue
            case .failed: anyFailed = true
            }
        }
        return anyFailed ? .failed : .notFound
    }

    public static let actionScheme = "vocab-action"

    static func page(_ s: Summary, lang: String, available: [String]) -> String {
        let esc = NetEntryStyle.esc
        var b = ""
        if available.count > 1 {
            b += "<div class=\"langs\">" + available.map { c in
                "<a href=\"\(actionScheme):wikilang/\(c)\" class=\"\(c == lang ? "on" : "")\">\(esc(name(c)))</a>"
            }.joined() + "</div>"
        }
        if let t = s.thumb { b += "<img class=\"thumb\" src=\"\(esc(t))\" alt=\"\"/>" }
        b += "<h2>\(esc(s.title))</h2>"
        if let d = s.description, !d.isEmpty { b += "<p class=\"desc\">\(esc(d))</p>" }
        for para in s.extract.components(separatedBy: "\n") where !para.trimmingCharacters(in: .whitespaces).isEmpty {
            b += "<p>\(esc(para))</p>"
        }
        if let url = s.url { b += "<p class=\"more\"><a href=\"\(esc(url))\">在维基百科中阅读全文 ↗</a></p>" }
        return NetEntryStyle.document(b + "<div class=\"clear\"></div>")
    }

    /// Kept for callers that build a page directly.
    public static func page(title: String, description: String?, extract: String, url: String?) -> String {
        page(Summary(title: title, description: description, extract: extract, url: url, thumb: nil), lang: "", available: [])
    }

    static func esc(_ s: String) -> String { NetEntryStyle.esc(s) }

    /// A placeholder / status entry shown in a network section.
    public static func statusEntry(_ message: String, dictionary d: DictionaryInfo, term: String) -> DictionaryEntry {
        let html = NetEntryStyle.document("<p class=\"note\">\(esc(message))</p>")
        return DictionaryEntry(id: "\(d.id)#status#\(message)#\(term)", dictionary: d, headword: term, html: html,
                               panelHTML: html, plainText: message, resourceDirectory: nil)
    }

    public static func entry(_ o: Outcome, dictionary d: DictionaryInfo, term: String) -> DictionaryEntry? {
        switch o {
        case let .found(a):
            return DictionaryEntry(id: "\(d.id)#\(a.lang)#\(a.title)", dictionary: d, headword: a.title, html: a.html,
                                   panelHTML: NetEntryStyle.panel(a.html), plainText: a.text, resourceDirectory: nil)
        case .notFound: return nil
        case .failed: return statusEntry("无法连接维基百科", dictionary: d, term: term)
        }
    }
}
