import Foundation

public extension DictionaryInfo {
    /// Dictionaries whose DCS search goes over the network (Dictionary.app's Wikipedia). A DCS call
    /// to them blocks for seconds, so they are never searched through DCS; see `WikipediaClient`.
    var isNetwork: Bool { id.localizedCaseInsensitiveContains("wikipedia") }
}

/// Fetches a Wikipedia summary ourselves, asynchronously, with a short timeout.
/// URLSession's default configuration uses the system proxy settings (HTTP/HTTPS/SOCKS/PAC).
public enum WikipediaClient {
    public enum Outcome: Sendable { case found(title: String, html: String, text: String), notFound, failed }

    public static let session: URLSession = {
        let c = URLSessionConfiguration.default        // honors CFNetworkCopySystemProxySettings
        c.timeoutIntervalForRequest = 5
        c.timeoutIntervalForResource = 6
        c.requestCachePolicy = .returnCacheDataElseLoad
        c.urlCache = URLCache(memoryCapacity: 4 << 20, diskCapacity: 0)
        return URLSession(configuration: c)
    }()

    public static func language(for term: String) -> String {
        term.range(of: #"\p{Han}"#, options: .regularExpression) != nil ? "zh" : "en"
    }

    public static func summaryURL(_ term: String, lang: String) -> URL? {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "_")
        guard !t.isEmpty, let e = t.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) else { return nil }
        return URL(string: "https://\(lang).wikipedia.org/api/rest_v1/page/summary/\(e)?redirect=true")
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    public static func fetch(_ term: String) async -> Outcome {
        let lang = language(for: term)
        guard let url = summaryURL(term, lang: lang) else { return .notFound }
        var req = URLRequest(url: url)
        req.setValue("Vocab/1.0 (macOS dictionary app)", forHTTPHeaderField: "User-Agent")
        if lang == "zh" { req.setValue("zh-cn", forHTTPHeaderField: "Accept-Language") }
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { return .notFound }
            guard code == 200, let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failed }
            if (j["type"] as? String) == "disambiguation" && (j["extract"] as? String ?? "").isEmpty { return .notFound }
            let title = j["title"] as? String ?? term
            let extract = j["extract"] as? String ?? ""
            guard !extract.isEmpty else { return .notFound }
            let page = ((j["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String
            var html = "<html><head><meta charset=\"utf-8\"></head><body><div class=\"wiki\"><h2>\(esc(title))</h2>"
            if let d = j["description"] as? String, !d.isEmpty { html += "<p style=\"color:gray\">\(esc(d))</p>" }
            html += "<p>\(esc(extract))</p>"
            if let page { html += "<p><a href=\"\(esc(page))\">在维基百科中阅读全文</a></p>" }
            html += "</div></body></html>"
            return .found(title: title, html: html, text: extract)
        } catch {
            return .failed
        }
    }

    /// A placeholder / status entry shown in the Wikipedia section.
    public static func statusEntry(_ message: String, dictionary d: DictionaryInfo, term: String) -> DictionaryEntry {
        let html = "<html><head><meta charset=\"utf-8\"></head><body><p style=\"color:gray\">\(esc(message))</p></body></html>"
        return DictionaryEntry(id: "\(d.id)#status#\(message)#\(term)", dictionary: d, headword: term, html: html,
                               panelHTML: html, plainText: message, resourceDirectory: nil)
    }

    public static func entry(_ o: Outcome, dictionary d: DictionaryInfo, term: String) -> DictionaryEntry? {
        switch o {
        case let .found(title, html, text):
            return DictionaryEntry(id: "\(d.id)#0#\(title)", dictionary: d, headword: title, html: html,
                                   panelHTML: html, plainText: text, resourceDirectory: nil)
        case .notFound: return nil
        case .failed: return statusEntry("无法连接维基百科", dictionary: d, term: term)
        }
    }
}
