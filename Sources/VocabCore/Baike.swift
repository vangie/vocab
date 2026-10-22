import Foundation

/// 百度百科. The lemma pages sit behind a captcha ("百度安全验证") for non-browser clients, so the
/// summary comes from Baike's open lemma-card API (abstract, description, info box, section list,
/// picture) and the entry links to the full page.
public enum BaikeClient {
    public static let id = "io.github.vangie.vocab.baidubaike"
    public static let dictionary = DictionaryInfo(id: id, name: "百度百科", shortName: "百度百科", bundleURL: nil)

    public struct Lemma: Sendable, Equatable {
        public var title: String, desc: String?, abstract: String
        public var card: [(name: String, value: String)]
        public var sections: [String]
        public var image: String?
        public var url: String
        /// The word has several meanings (义项); this is the main one.
        public var hasOthers: Bool
        public static func == (a: Lemma, b: Lemma) -> Bool { a.title == b.title && a.abstract == b.abstract }
    }
    public enum Outcome: Sendable { case found(Lemma), notFound, failed }

    public static func apiURL(_ term: String) -> URL? {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var c = URLComponents(string: "https://baike.baidu.com/api/openapi/BaikeLemmaCardApi")!
        c.queryItems = [.init(name: "scope", value: "103"), .init(name: "format", value: "json"), .init(name: "appid", value: "379020"),
                        .init(name: "bk_key", value: t), .init(name: "bk_length", value: "1200")]
        return c.url
    }

    public static func itemURL(_ term: String) -> String {
        let e = term.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? term
        return "https://baike.baidu.com/item/\(e)"
    }

    static func stripTags(_ s: String) -> String {
        // Citation markers (<sup>615</sup>) would read as part of the value.
        var t = s.replacingOccurrences(of: #"<sup[^>]*>.*?</sup>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (a, b) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parse the lemma-card JSON; nil when there is no entry.
    public static func parse(_ data: Data, term: String) -> Lemma? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = j["title"] as? String, !title.isEmpty else { return nil }
        let abstract = stripTags(j["abstract"] as? String ?? "")
        guard !abstract.isEmpty else { return nil }
        var card: [(String, String)] = []
        for c in j["card"] as? [[String: Any]] ?? [] {
            guard let n = c["name"] as? String else { continue }
            let vals = (c["format"] as? [String] ?? c["value"] as? [String] ?? []).map(stripTags).filter { !$0.isEmpty }
            if !vals.isEmpty { card.append((n, vals.joined(separator: "、"))) }
        }
        let sections = (j["catalog"] as? [String] ?? []).map(stripTags).filter { !$0.isEmpty }
        let others = (j["hasOther"] as? Int ?? 0) != 0 || (j["hasOther"] as? Bool ?? false)
        var image = j["image"] as? String
        if image?.isEmpty == true { image = nil }
        return Lemma(title: title, desc: (j["desc"] as? String).flatMap { $0.isEmpty ? nil : $0 }, abstract: abstract,
                     card: card, sections: sections, image: image, url: itemURL(title), hasOthers: others)
    }

    // Results by term (process lifetime). A failure is not cached, so it is retried next time.
    nonisolated(unsafe) private static var cache: [String: Outcome] = [:]
    private static let lock = NSLock()

    public static func fetch(_ term: String) async -> Outcome {
        let key = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lock.lock(); let hit = cache[key]; lock.unlock()
        if let hit { return hit }
        guard let url = apiURL(term) else { return .notFound }
        var req = URLRequest(url: url)
        req.setValue("Vocab/1.0 (macOS dictionary app)", forHTTPHeaderField: "User-Agent")
        let o: Outcome
        do {
            let (data, resp) = try await WikipediaClient.session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return .failed }
            o = parse(data, term: term).map { .found($0) } ?? .notFound
        } catch { return .failed }
        lock.lock(); cache[key] = o; lock.unlock()
        return o
    }

    public static func page(_ l: Lemma, term: String) -> String {
        let esc = NetEntryStyle.esc
        var b = ""
        if let img = l.image { b += "<img class=\"thumb\" src=\"\(esc(img))\" alt=\"\"/>" }
        b += "<h2>\(esc(l.title))</h2>"
        if let d = l.desc { b += "<p class=\"desc\">\(esc(d))</p>" }
        if l.hasOthers {
            b += "<p class=\"note\">「\(esc(term))」有多个义项，这里是最常见的一个。<a href=\"\(esc(itemURL(term)))\">查看全部义项 ↗</a></p>"
        }
        for p in l.abstract.components(separatedBy: "\n") where !p.trimmingCharacters(in: .whitespaces).isEmpty { b += "<p>\(esc(p))</p>" }
        b += "<div class=\"clear\"></div>"
        if !l.card.isEmpty {
            b += "<table class=\"card\">" + l.card.prefix(14).map { "<tr><td class=\"k\">\(esc($0.name))</td><td>\(esc($0.value))</td></tr>" }.joined() + "</table>"
        }
        if !l.sections.isEmpty {
            b += "<p class=\"toc\"><b>目录</b>　" + l.sections.prefix(16).map(esc).joined(separator: " · ") + "</p>"
        }
        b += "<p class=\"more\"><a href=\"\(esc(l.url))\">在百度百科中查看全文 ↗</a></p>"
        return NetEntryStyle.document(b)
    }

    public static func entry(_ o: Outcome, term: String) -> DictionaryEntry? {
        let d = dictionary
        switch o {
        case let .found(l):
            let html = page(l, term: term)
            return DictionaryEntry(id: "\(d.id)#\(l.title)", dictionary: d, headword: l.title, html: html,
                                   panelHTML: html, plainText: l.abstract, resourceDirectory: nil)
        case .notFound: return nil
        case .failed: return WikipediaClient.statusEntry("无法连接百度百科", dictionary: d, term: term)
        }
    }
}
