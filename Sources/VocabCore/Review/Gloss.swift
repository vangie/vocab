import Foundation

/// A short meaning for a word, pulled from dictionary HTML.
public struct Gloss: Hashable, Sendable {
    public var chinese: String?
    public var english: String?
    public init(chinese: String? = nil, english: String? = nil) { self.chinese = chinese; self.english = english }
    public var isEmpty: Bool { (chinese ?? "").isEmpty && (english ?? "").isEmpty }
    /// What an option shows: Chinese when we have it (short, like 百词斩), else English.
    public var short: String { chinese ?? english ?? "" }
}

public enum GlossExtractor {
    /// Inner HTML of the first element whose start tag matches `pattern`, balancing nested tags of the same name.
    static func elements(_ html: String, tag: String, classPattern: String, limit: Int = 12) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "<\(tag)\\b[^>]*class=\"(\(classPattern))\"[^>]*>") else { return [] }
        let ns = html as NSString
        var out: [String] = []
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)).prefix(limit) {
            var depth = 1; var i = m.range.location + m.range.length
            let start = i
            while i < ns.length, depth > 0 {
                let rest = ns.substring(from: i)
                guard let lt = rest.firstIndex(of: "<") else { break }
                i += rest.distance(from: rest.startIndex, to: lt)
                if ns.substring(from: i).hasPrefix("</\(tag)>") { depth -= 1; if depth == 0 { break }; i += tag.count + 3 }
                else if ns.substring(from: i).hasPrefix("<\(tag)") { depth += 1; i += tag.count + 1 }
                else { i += 1 }
            }
            out.append(ns.substring(with: NSRange(location: start, length: max(0, i - start))))
        }
        return out
    }

    public static func text(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (a, b) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    static func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }

    static func hasCJK(_ s: String) -> Bool { s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }

    /// English definition: LDOCE `DEF`, Oxford `df`, Macmillan `DEFINITION`.
    public static func english(fromHTML html: String, maxLength: Int = 120) -> String? {
        for el in elements(html, tag: "span", classPattern: "DEF[^\"]*|df[^\"]*|DEFINITION[^\"]*|def") {
            if el.contains("cn_txt") { continue }
            let t = text(el)
            if t.count >= 3, !hasCJK(t) { return clip(t, maxLength) }
        }
        return nil
    }

    /// Chinese: LDOCE's translation of the first sense (`cn_txt`), or the Oxford E–C `trans` (not pinyin).
    public static func chinese(fromHTML html: String, maxLength: Int = 28) -> String? {
        // LDOCE puts the sense's translation inside a DEF span; signposts ("child 孩子") also carry cn_txt.
        for el in elements(html, tag: "span", classPattern: "DEF[^\"]*") where el.contains("cn_txt") {
            let t = text(el); if hasCJK(t) { return clip(t, maxLength) }
        }
        for el in elements(html, tag: "span", classPattern: "trans") {
            let t = text(el); if hasCJK(t) { return clip(t, maxLength) }
        }
        for el in elements(html, tag: "span", classPattern: "cn_txt[^\"]*") {
            let t = text(el); if hasCJK(t) { return clip(t, maxLength) }
        }
        for el in elements(html, tag: "span", classPattern: "trans") {
            let t = text(el); if hasCJK(t) { return clip(t, maxLength) }
        }
        return nil
    }

    public static func gloss(fromHTML html: String) -> Gloss {
        Gloss(chinese: chinese(fromHTML: html), english: english(fromHTML: html))
    }

    /// CJK bigrams, used to spot near-synonyms among Chinese glosses.
    static func bigrams(_ s: String) -> Set<String> {
        let c = Array(s.filter { hasCJK(String($0)) })
        guard c.count >= 2 else { return Set(c.map(String.init)) }
        return Set((0..<(c.count - 1)).map { String(c[$0...$0 + 1]) })
    }

    static func normalized(_ s: String) -> String {
        s.replacingOccurrences(of: "（[^）]*）|〔[^〕]*〕|\\([^)]*\\)", with: "", options: .regularExpression)
            .filter { $0.isLetter || $0.isNumber }.lowercased()
    }

    /// Practically the same meaning: equal after stripping brackets/punctuation, or mostly the same words.
    public static func nearIdentical(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
        let x = normalized(a), y = normalized(b)
        if x == y { return true }
        if hasCJK(x) || hasCJK(y) {
            let p = bigrams(x), q = bigrams(y)
            guard !p.isEmpty, !q.isEmpty else { return false }
            return Double(p.intersection(q).count) / Double(p.union(q).count) >= 0.6
        }
        let p = Set(x.split(separator: " ")), q = Set(y.split(separator: " "))
        return Double(p.intersection(q).count) / Double(max(1, p.union(q).count)) >= 0.8
    }

    /// True if two Chinese glosses share a two-character word (e.g. 调整 / 调整…以适用): likely synonyms.
    public static func overlaps(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        return !bigrams(a).isDisjoint(with: bigrams(b))
    }
}
