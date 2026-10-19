import Foundation

/// Confusable wrong answers for a word, 百词斩-style.
public enum Distractors {
    public struct Candidate: Hashable, Sendable {
        public let word: String
        public let score: Double     // lower is more confusable
    }

    /// A rough consonant skeleton so "adapt"/"adept"/"adopt" and "affect"/"effect" collide.
    public static func phoneticKey(_ w: String) -> String {
        var s = w.lowercased()
        for (a, b) in [("ph", "f"), ("ck", "k"), ("qu", "kw"), ("q", "k"), ("x", "ks"), ("z", "s"),
                       ("ce", "se"), ("ci", "si"), ("cy", "sy"), ("c", "k"), ("gh", "g"), ("wh", "w"), ("kn", "n")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        var out = ""
        for (i, ch) in s.enumerated() {
            if "aeiouy".contains(ch) { if i == 0 { out.append("a") }; continue }
            if out.last != ch { out.append(ch) }
        }
        return out
    }

    static func commonPrefix(_ a: String, _ b: String) -> Int {
        zip(a.lowercased(), b.lowercased()).prefix { $0 == $1 }.count
    }
    static func commonSuffix(_ a: String, _ b: String) -> Int {
        zip(a.lowercased().reversed(), b.lowercased().reversed()).prefix { $0 == $1 }.count
    }

    /// Same word or a direct derivative (adapt → adapted, adaptable): never a fair distractor.
    public static func isSameFamily(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        if x == y { return true }
        let (s, l) = x.count <= y.count ? (x, y) : (y, x)
        if s.count >= 4 && l.hasPrefix(s) { return true }
        // adapt/adaptation, decide/decision: shared stem of all but the last letter or two.
        let stem = s.count >= 6 ? String(s.dropLast(2)) : s.count >= 5 ? String(s.dropLast(1)) : s
        return stem.count >= 4 && l.count > s.count && l.hasPrefix(stem) && l.count - s.count <= 5
    }

    /// Spelling variants likely to be real, confusable words: vowel swaps (adapt → adopt, adept;
    /// affect → effect), doubled/undoubled letters and adjacent transpositions.
    public static func variants(_ word: String) -> [String] {
        let w = Array(word.lowercased()); let vowels: [Character] = ["a", "e", "i", "o", "u"]
        var out = Set<String>()
        for i in w.indices where vowels.contains(w[i]) {
            for v in vowels where v != w[i] { var x = w; x[i] = v; out.insert(String(x)) }
        }
        for i in w.indices {
            var d = w; d.insert(w[i], at: i); out.insert(String(d))
            if i > 0, w[i] == w[i - 1] { var u = w; u.remove(at: i); out.insert(String(u)) }
            if i + 1 < w.count { var t = w; t.swapAt(i, i + 1); out.insert(String(t)) }
        }
        out.remove(String(w))
        return out.sorted()
    }

    /// Rank candidate words by how confusable they are with `target`, dropping same-family words,
    /// true synonyms (two right answers) and junk. `book` words get a small bonus (you've met them).
    public static func rank(target: String, candidates: [String], synonyms: Set<String> = [],
                            book: Set<String> = [], limit: Int = 8) -> [Candidate] {
        let t = target.lowercased()
        let tKey = phoneticKey(t)
        let tRoots = Set(RootTable.matches(t).filter { $0.morpheme.kind == .root }.map(\.morpheme))
        let syn = Set(synonyms.map { $0.lowercased() })
        let lowerBook = Set(book.map { $0.lowercased() })
        let properTarget = target.first?.isUppercase ?? false
        var seen = Set<String>(); var out: [Candidate] = []
        // Curated confusables come first, whatever the other rules say.
        for (i, p) in Confusables.partners(of: t).enumerated() where seen.insert(p).inserted {
            out.append(Candidate(word: p, score: -100 + Double(i)))
        }
        for c in candidates {
            let w = c.trimmingCharacters(in: .whitespaces)
            let l = w.lowercased()
            guard w.count >= 3, w.allSatisfy({ $0.isLetter }), seen.insert(l).inserted else { continue }
            guard (w.first?.isUppercase ?? false) == properTarget || lowerBook.contains(l) else { continue }
            guard !syn.contains(l), !isSameFamily(t, l) else { continue }
            let d = Suggester.distance(t, l)
            let inBook = lowerBook.contains(l)
            let sameRoot = !tRoots.isEmpty && !tRoots.isDisjoint(with: Set(RootTable.matches(l).map(\.morpheme)))
            let key = phoneticKey(l)
            let maxD = max(2, t.count / 2)
            guard d <= maxD || inBook || sameRoot else { continue }
            var s = Double(d) * 2
            if key == tKey { s -= 2 } else if Suggester.distance(key, tKey) <= 1 { s -= 1 }
            s -= Double(min(commonPrefix(t, l), 4)) * 0.5
            s -= Double(min(commonSuffix(t, l), 4)) * 0.5
            s += Double(abs(l.count - t.count)) * 0.3
            if inBook { s -= 1 }
            if sameRoot { s -= 1 }
            out.append(Candidate(word: w, score: s))
        }
        return Array(out.sorted { ($0.score, $0.word) < ($1.score, $1.word) }.prefix(limit))
    }

    /// Strong look/sound-alike relationship: a near miss in spelling or the same consonant skeleton.
    public static func looksAlike(_ a: String, _ b: String) -> Bool {
        let d = Suggester.distance(a, b)
        return d <= 2 || phoneticKey(a) == phoneticKey(b) || (commonPrefix(a, b) >= 3 && d <= 3)
    }

    /// Should `candidate` stay as a distractor for `target`? Curated confusables always stay.
    /// Otherwise drop thesaurus synonyms and near-identical glosses; when the spelling link is weak,
    /// also drop any Chinese gloss sharing a two-character word (likely a second right answer).
    public static func keep(target: String, candidate: String, targetGloss: Gloss, candidateGloss: Gloss,
                            synonyms: Set<String> = []) -> Bool {
        let t = target.lowercased(), c = candidate.lowercased()
        if Confusables.partners(of: t).contains(c) { return true }
        if synonyms.contains(c) { return false }
        if GlossExtractor.nearIdentical(targetGloss.chinese, candidateGloss.chinese) { return false }
        if GlossExtractor.nearIdentical(targetGloss.english, candidateGloss.english) { return false }
        if looksAlike(t, c) { return true }
        return !GlossExtractor.overlaps(targetGloss.chinese, candidateGloss.chinese)
    }

    /// Words from a thesaurus entry's plain text ("modify, alter, make alterations to, change, …").
    /// Antonyms are cut off; multi-word phrases are dropped.
    public static func thesaurusWords(_ text: String) -> Set<String> {
        var body = text
        if let r = body.range(of: "ANTONYMS") { body = String(body[..<r.lowerBound]) }
        var out = Set<String>()
        for part in body.split(whereSeparator: { ",;.:".contains($0) }) {
            let p = part.trimmingCharacters(in: .whitespaces).lowercased()
            let words = p.split(separator: " ")
            if let last = words.last, words.count <= 2 { out.insert(String(last)) }
        }
        return out
    }
}
