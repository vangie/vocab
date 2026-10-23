import Foundation

/// Which letter case a wordbook word is stored in: the dictionary headword's.
public enum WordCase {
    /// Headword text without syllable dots, homograph numbers or stray punctuation ("At·lan·tic2" → "Atlantic").
    public static func clean(_ h: String) -> String {
        h.replacingOccurrences(of: "·", with: "").replacingOccurrences(of: "‧", with: "")
            .replacingOccurrences(of: "[0-9]+$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `input` in the case a dictionary uses: lowercase if any dictionary lists it lowercase
    /// ("Steer" → "steer"), else the capitalized headword ("atlantic" → "Atlantic"), else as typed.
    public static func canonical(_ input: String, headwords: [String]) -> String {
        let w = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = headwords.map(clean).filter { $0.caseInsensitiveCompare(w) == .orderedSame }
        if let lower = matches.first(where: { $0 == $0.lowercased() }) { return lower }
        if matches.contains(w) { return w }
        return matches.first ?? w
    }

    /// Headwords (entry headword and `d:title`) of `word` in the given dictionaries.
    public static func headwords(_ word: String, service: DictionaryService = .shared, in dicts: [DictionaryInfo]) -> [String] {
        service.lookup(word, in: dicts, maxPerDictionary: 4).flatMap { e -> [String] in
            var out = [e.headword]
            if let r = e.html.range(of: #"d:title="[^"]*""#, options: .regularExpression) {
                out.append(String(e.html[r].dropFirst(9).dropLast()))
            }
            return out
        }
    }
}
