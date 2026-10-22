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

    // MARK: exact-word rule
    // A word's recording and IPA must be the displayed word's own: "writing" never borrows
    // "write"'s audio, "went" never "go"'s, "apples" never "apple"'s. No exact match: TTS / no IPA.

    /// Headword or word, compared loosely only in spelling marks: case, syllable dots, stress marks.
    public static func normalized(_ s: String) -> String {
        let drop = CharacterSet(charactersIn: "·‧•ˈˌ'’ ")
        return String(String.UnicodeScalarView(s.lowercased().unicodeScalars.filter { !drop.contains($0) }))
            .trimmingCharacters(in: .decimalDigits)
    }

    /// The entry's own headword: its `d:title` (DCS reports the searched index key as the headword,
    /// e.g. Oxford's "go" entry comes back as "went"), else the reported headword.
    public static func entryTitle(_ e: DictionaryEntry) -> String {
        if let r = e.html.range(of: #"d:title="[^"]*""#, options: .regularExpression) {
            let t = e.html[r].dropFirst("d:title=\"".count).dropLast()
            if !t.isEmpty { return String(t).replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'") }
        }
        return e.headword
    }

    /// Entries whose headword is exactly `word`.
    public static func exactEntries(_ word: String, _ entries: [DictionaryEntry]) -> [DictionaryEntry] {
        let w = normalized(word)
        return entries.filter { normalized(entryTitle($0)) == w }
    }

    /// The word a pronunciation file is named after, when the name says so:
    /// `ameProns/writing__us_4.mp3` (OALD10) → "writing", `breProns/writing0205.mp3` → "writing".
    /// Coded names (Macmillan `zzz_us_A…`, LDOCE `p008-…`) give nil.
    public static func fileWord(_ ref: String) -> String? {
        var b = ((ref as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        b = b.replacingOccurrences(of: #"__(us|gb|uk)(_\d+)?$"#, with: "", options: .regularExpression)
        b = b.trimmingCharacters(in: .decimalDigits)
        guard !b.isEmpty, !b.hasPrefix("zzz"), b.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "_" }) else { return nil }
        return b.replacingOccurrences(of: "_", with: " ")
    }

    /// The recording of exactly `word`: from an exact-headword entry (American first), else a file
    /// named after the word inside another entry (OALD10 lists "written__us_3.mp3" under "write").
    public static func audio(for word: String, in entries: [DictionaryEntry]) -> URL? {
        let exact = exactEntries(word, entries)
        if let u = QuestionFactory.pronunciation(in: exact) { return u }
        let w = normalized(word)
        for pref in ["ameProns", "us_", ""] {
            for e in entries where !exact.contains(where: { $0.id == e.id }) {
                guard let dir = e.resourceDirectory else { continue }
                for a in EntryHTML.audioReferences(in: e.html) where !a.contains("exaProns") && (pref.isEmpty || a.contains(pref)) {
                    guard let f = fileWord(a), normalized(f) == w else { continue }
                    let u = dir.appendingPathComponent(a)
                    if FileManager.default.fileExists(atPath: u.path) { return u }
                }
            }
        }
        return nil
    }

    /// Dictionaries with recordings, consulted even when not enabled for lookup.
    public static let audioDictionaryIDs = ["com.vangie.dict.oald10", "LDOCE5", "Macmillan2"]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Phonetic] = [:]

    /// Cached per word; looks the word up (1 entry per dictionary). Call off the main thread.
    public static func lookup(_ word: String, in dicts: [DictionaryInfo], service: DictionaryService = .shared) -> Phonetic {
        let key = word.lowercased()
        lock.lock(); if let p = cache[key] { lock.unlock(); return p }; lock.unlock()
        var list = dicts.filter { !$0.isNetwork }
        let avail = service.availableDictionaries()
        for id in audioDictionaryIDs where !list.contains(where: { $0.id == id }) {
            if let d = avail.first(where: { $0.id == id }) { list.append(d) }
        }
        // Several entries per dictionary: the base form ("write") often comes before "writing".
        let entries = service.lookup(word, in: list, maxPerDictionary: 4)
        let p = Phonetic(ipa: ipa(inHTML: exactEntries(word, entries).map(\.html)), audio: audio(for: word, in: entries))
        lock.lock(); cache[key] = p; lock.unlock()
        return p
    }
}
