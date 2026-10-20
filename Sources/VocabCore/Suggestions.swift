import AppKit
import NaturalLanguage

/// One row in the sidebar.
public struct Suggestion: Hashable, Sendable, Identifiable {
    public enum Kind: Sendable { case match, spelling }
    public let word: String
    public let kind: Kind
    /// Secondary text (e.g. pinyin from a Chinese dictionary's display headword).
    public var detail: String? = nil
    public var id: String { "\(kind)|\(word)" }
    public init(word: String, kind: Kind, detail: String? = nil) { self.word = word; self.kind = kind; self.detail = detail }
}

/// Autocomplete, spelling correction and lemmatization on top of DictionaryService.
public enum Suggester {
    /// Chinese dictionaries list display headwords with the reading appended
    /// ("朝三暮四 zhāosān-mùsì"); the lookup key is the Han part. Returns (key, reading).
    public static func splitHeadword(_ h: String) -> (word: String, reading: String?) {
        let t = h.trimmingCharacters(in: .whitespaces)
        guard let r = t.range(of: #"^(\p{Han}[\p{Han}\p{P}0-9]*)\s+([\p{Latin}\p{M}0-9·'’\- ]+)$"#, options: .regularExpression),
              r == t.startIndex..<t.endIndex,
              let sp = t.firstIndex(where: { $0.isWhitespace }) else { return (t, nil) }
        let word = String(t[..<sp])
        let reading = t[sp...].trimmingCharacters(in: .whitespaces)
        return (word, reading.isEmpty ? nil : reading)
    }

    /// Clean headwords to lookup keys (deduped later by `rank`) and remember the first reading per key.
    public static func normalize(_ headwords: [String]) -> (words: [String], readings: [String: String]) {
        var words: [String] = [], readings: [String: String] = [:]
        for h in headwords {
            let (w, r) = splitHeadword(h)
            words.append(w)
            if let r, readings[w] == nil { readings[w] = r }
        }
        return (words, readings)
    }

    /// Dedupe case-insensitively and rank: exact match, then prefix matches by
    /// length (single words before phrases), then alphabetically.
    public static func rank(_ headwords: [String], query: String, limit: Int = 60) -> [String] {
        let q = query.lowercased()
        var seen = Set<String>(); var uniq: [String] = []
        for h in headwords {
            let t = h.trimmingCharacters(in: .whitespaces)
            let k = t.lowercased()
            if t.isEmpty || seen.contains(k) { continue }
            seen.insert(k); uniq.append(t)
        }
        func key(_ w: String) -> (Int, Int, Int, Int, String) {
            let l = w.lowercased()
            let exact = l == q ? 0 : 1
            let prefix = l.hasPrefix(q) ? 0 : 1
            let phrase = w.contains(where: { $0 == " " || $0 == "(" || $0 == "," }) ? 1 : 0
            // Prefer lower-case forms (common words) over proper nouns/abbreviations.
            let lower = w == l ? 0 : 1
            return (exact, prefix, phrase * 1000 + w.count, lower, l)
        }
        return Array(uniq.sorted { key($0) < key($1) }.prefix(limit))
    }

    /// Optimal string alignment distance (Damerau–Levenshtein with adjacent transpositions).
    public static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a.lowercased()), y = Array(b.lowercased())
        if x.isEmpty { return y.count }; if y.isEmpty { return x.count }
        var d = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in 0...x.count { d[i][0] = i }
        for j in 0...y.count { d[0][j] = j }
        for i in 1...x.count {
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[x.count][y.count]
    }

    /// Base form of an inflected English word ("appalled" → "appal"), or nil.
    public static func lemma(_ word: String) -> String? {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !w.contains(" ") else { return nil }
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = w
        tagger.setLanguage(.english, range: w.startIndex..<w.endIndex)
        let (tag, _) = tagger.tag(at: w.startIndex, unit: .word, scheme: .lemma)
        guard let l = tag?.rawValue, !l.isEmpty, l.lowercased() != w.lowercased() else { return nil }
        return l
    }

    /// Spelling guesses from the system spell checker (English).
    public static func spellingGuesses(_ word: String) -> [String] {
        let run = {
            let sc = NSSpellChecker.shared
            let r = NSRange(location: 0, length: (word as NSString).length)
            var out = sc.guesses(forWordRange: r, in: word, language: "en", inSpellDocumentWithTag: 0) ?? []
            if let c = sc.correction(forWordRange: r, in: word, language: "en", inSpellDocumentWithTag: 0), !out.contains(c) {
                out.insert(c, at: 0)
            }
            return out
        }
        if Thread.isMainThread { return run() }
        return DispatchQueue.main.sync(execute: run)
    }

    public struct Result: Sendable {
        public let matches: [String]
        public let spelling: [String]
        public var readings: [String: String] = [:]
        public init(matches: [String], spelling: [String], readings: [String: String] = [:]) {
            self.matches = matches; self.spelling = spelling; self.readings = readings
        }
        public var all: [Suggestion] {
            matches.map { Suggestion(word: $0, kind: .match, detail: readings[$0]) } + spelling.map { Suggestion(word: $0, kind: .spelling) }
        }
    }

    /// Everything the sidebar needs for a query.
    public static func suggest(_ query: String, in dicts: [DictionaryInfo],
                               service: DictionaryService = .shared,
                               guesses: (String) -> [String] = spellingGuesses) -> Result {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return Result(matches: [], spelling: []) }
        var raw = service.headwords(q, method: 0, in: dicts, maxPerDictionary: 5)   // exact + indexed inflections
        raw += service.headwords(q, method: 1, in: dicts, maxPerDictionary: 40)     // prefix
        if raw.isEmpty, let l = lemma(q) { raw += service.headwords(l, method: 0, in: dicts, maxPerDictionary: 5) }
        let norm = normalize(raw)
        let matches = rank(norm.words, query: q)

        // Spelling suggestions when there are few direct matches.
        var spelling: [String] = []
        let haveExact = matches.contains { $0.lowercased() == q.lowercased() }
        if !haveExact && matches.count < 8 && q.count >= 3 && !q.contains(" ") {
            var guessed: [String] = []
            for g in guesses(q).prefix(8) where service.hasEntry(g, in: dicts) { guessed.append(g) }
            // Edit distance against headwords sharing the first letter.
            let pool = service.headwords(String(q.prefix(1)), method: 1, in: dicts, maxPerDictionary: 4000)
            let maxD = q.count <= 4 ? 1 : 2
            let near = rank(pool.filter { !$0.contains(" ") && abs($0.count - q.count) <= maxD && distance($0, q) <= maxD }, query: q, limit: 200)
            // Closest first; among equals, words the spell checker also proposed win.
            var cands = (near + guessed).sorted {
                let a = (distance($0, q), guessed.contains($0) ? 0 : 1), b = (distance($1, q), guessed.contains($1) ? 0 : 1)
                return a < b
            }
            cands = Array(cands.prefix(6))
            // Expand the best correction to its longer forms ("vocab" → "vocabulary").
            if let best = cands.first {
                cands.insert(contentsOf: rank(service.headwords(best, method: 1, in: dicts, maxPerDictionary: 10), query: best, limit: 3).filter { $0.lowercased() != best.lowercased() }, at: 1)
            }
            let taken = Set(matches.map { $0.lowercased() })
            var seen = Set<String>()
            spelling = cands.filter { let k = $0.lowercased(); return !taken.contains(k) && k != q.lowercased() && seen.insert(k).inserted }
            spelling = Array(spelling.prefix(8))
        }
        return Result(matches: matches, spelling: spelling, readings: norm.readings)
    }

    /// Entries for a word, falling back to its lemma (for taps on inflected words).
    public static func lookupWithFallback(_ word: String, in dicts: [DictionaryInfo],
                                          service: DictionaryService = .shared) -> (word: String, entries: [DictionaryEntry]) {
        let e = service.lookup(word, in: dicts)
        if !e.isEmpty { return (word, e) }
        if let l = lemma(word) {
            let le = service.lookup(l, in: dicts)
            if !le.isEmpty { return (l, le) }
        }
        let lower = word.lowercased()
        if lower != word {
            let le = service.lookup(lower, in: dicts)
            if !le.isEmpty { return (lower, le) }
        }
        return (word, [])
    }
}
