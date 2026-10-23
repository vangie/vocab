import Foundation

extension DictionaryEntry {
    /// Clean one-line summary for the wordbook's 释义 column: "/ipa/ 中文 · English".
    /// Falls back to the plain-text snippet with the headword and BrE/NAmE labels stripped.
    public var summary: String { Self.makeSummary(html: html, plainText: plainText, headword: headword) }

    public static func makeSummary(html: String, plainText: String, headword: String, limit: Int = 160) -> String {
        let g = GlossExtractor.gloss(fromHTML: html)
        let ipa = Phonetics.ipa(inHTML: [html]).map { "/\($0.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")))/" }
        var parts: [String] = []
        if let c = g.chinese, !c.isEmpty { parts.append(c) }
        if let e = g.english, !e.isEmpty { parts.append(e) }
        if !parts.isEmpty {
            let s = ([ipa].compactMap { $0 } + [parts.joined(separator: " · ")]).joined(separator: " ")
            return s.count > limit ? String(s.prefix(limit)) + "…" : s
        }
        return makeSnippet(cleanPlainText(plainText, headword: headword), headword: headword, limit: limit)
    }

    /// Drop a leading headword (with syllable dots / homograph digits) and glued BrE/NAmE/AmE labels.
    static func cleanPlainText(_ text: String, headword: String) -> String {
        var s = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let bare = s.replacingOccurrences(of: "·", with: "")
        if bare.lowercased().hasPrefix(headword.lowercased()) {
            // Remove the headword's characters (and dots) from the front.
            var need = headword.count; var i = s.startIndex
            while i < s.endIndex && need > 0 { if s[i] != "·" { need -= 1 }; i = s.index(after: i) }
            s = String(s[i...]).replacingOccurrences(of: "^[0-9]+", with: "", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: "(BrE|NAmE|AmE|NAm)(?=\\S)", with: " $1 ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " |▪"))
    }
}
