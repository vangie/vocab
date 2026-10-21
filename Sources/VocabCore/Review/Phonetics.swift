import Foundation

/// IPA + recorded pronunciation of a word, from the installed dictionaries.
public struct Phonetic: Sendable, Equatable {
    public var ipa: String?
    public var audio: URL?
    public init(ipa: String? = nil, audio: URL? = nil) { self.ipa = ipa; self.audio = audio }
}

public enum Phonetics {
    /// IPA from dictionary HTML, American first:
    /// 1. Oxford (牛津英汉汉英) `class="ph"` with `dialect="AmE"`;
    /// 2. LDOCE `class="PRON"` (British; LDOCE only gives US differences as fragments);
    /// 3. Oxford `dialect="BrE"`.
    public static func ipa(inHTML htmls: [String]) -> String? {
        func oxford(_ dialect: String) -> String? {
            for h in htmls {
                guard let re = try? NSRegularExpression(pattern: "<span[^>]*\\bdialect=\"\(dialect)\"[^>]*\\bclass=\"ph\"[^>]*>([^<]+)<") else { continue }
                let ns = h as NSString
                if let m = re.firstMatch(in: h, range: NSRange(location: 0, length: ns.length)) {
                    let t = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { return t }
                }
            }
            return nil
        }
        if let us = oxford("AmE") { return us }
        for h in htmls {
            for el in GlossExtractor.elements(h, tag: "span", classPattern: "PRON", limit: 1) {
                let t = GlossExtractor.text(el).trimmingCharacters(in: CharacterSet(charactersIn: " /"))
                if !t.isEmpty { return t }
            }
        }
        return oxford("BrE")
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Phonetic] = [:]

    /// Cached per word; looks the word up (1 entry per dictionary). Call off the main thread.
    public static func lookup(_ word: String, in dicts: [DictionaryInfo], service: DictionaryService = .shared) -> Phonetic {
        let key = word.lowercased()
        lock.lock(); if let p = cache[key] { lock.unlock(); return p }; lock.unlock()
        let entries = service.lookup(word, in: dicts.filter { !$0.isNetwork }, maxPerDictionary: 1)
        let p = Phonetic(ipa: ipa(inHTML: entries.map(\.html)), audio: QuestionFactory.pronunciation(in: entries))
        lock.lock(); cache[key] = p; lock.unlock()
        return p
    }
}
