import Foundation
import CoreFoundation

public enum Hyphenation {
    static let dots: Set<Character> = ["·", "‧", "•"]

    /// Syllables from a dictionary's headword ("a·dapt", "At·lan·tic2", LDOCE "re‧quest"), or nil.
    public static func fromDictionaryText(_ text: String, word: String) -> [String]? {
        let target = word.lowercased()
        guard let re = try? NSRegularExpression(pattern: "[A-Za-z]+(?:[·‧•][A-Za-z]+)+") else { return nil }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let tok = ns.substring(with: m.range)
            let parts = tok.split(whereSeparator: { dots.contains($0) }).map(String.init)
            var letters = parts.joined().lowercased()
            guard letters.hasSuffix(target) else { continue }
            // Longman runs the headword into itself ("adaptadapta‧dapt"): trim the leading junk.
            var p = parts
            while letters.count > target.count, !p.isEmpty {
                let extra = letters.count - target.count
                if p[0].count <= extra { letters.removeFirst(p[0].count); p.removeFirst() }
                else { p[0] = String(p[0].dropFirst(extra)); letters.removeFirst(extra) }
            }
            guard letters == target, p.count >= 1 else { continue }
            // Restore the word's own casing.
            var out: [String] = []; var i = word.startIndex
            for s in p { let j = word.index(i, offsetBy: s.count); out.append(String(word[i..<j])); i = j }
            return out
        }
        return nil
    }

    /// Fallback: the system hyphenator (CFStringGetHyphenationLocationBeforeIndex).
    public static func system(_ word: String, locale: String = "en_US") -> [String] {
        let s = word as CFString
        let n = CFStringGetLength(s)
        guard n > 3, let loc = CFLocaleCreate(nil, CFLocaleIdentifier(rawValue: locale as CFString)),
              CFStringIsHyphenationAvailableForLocale(loc) else { return [word] }
        var cuts: [Int] = []
        var idx = n
        while idx > 0 {
            let h = CFStringGetHyphenationLocationBeforeIndex(s, idx, CFRange(location: 0, length: n), 0, loc, nil)
            if h == kCFNotFound || h <= 0 || h >= idx { break }
            cuts.append(h); idx = h
        }
        cuts.sort()
        return split(word, at: cuts)
    }

    public static func split(_ word: String, at cuts: [Int]) -> [String] {
        let a = Array(word); var out: [String] = []; var last = 0
        for c in cuts.sorted() where c > last && c < a.count { out.append(String(a[last..<c])); last = c }
        out.append(String(a[last...]))
        return out
    }

    public static func cuts(_ parts: [String]) -> [Int] {
        var r: [Int] = []; var n = 0
        for p in parts.dropLast() { n += p.count; r.append(n) }
        return r
    }

    /// Four splits for a "pick the correct split" question: the right one first, then plausible wrong ones
    /// (a boundary moved by one letter, one added, one removed). Nil when the word has one syllable.
    public static func options(correct parts: [String], count: Int = 4) -> [[String]]? {
        guard parts.count >= 2 else { return nil }
        let word = parts.joined(); let n = word.count
        let right = cuts(parts)
        var seen: Set<[Int]> = [right]; var wrong: [[Int]] = []
        func add(_ c: [Int]) {
            let c2 = Array(Set(c.filter { $0 > 0 && $0 < n })).sorted()
            guard !c2.isEmpty, !seen.contains(c2) else { return }
            // No one-letter syllables except a leading vowel, so options look plausible.
            let sizes = zip([0] + c2, c2 + [n]).map { $1 - $0 }
            guard !sizes.dropFirst().contains(1), !(sizes.last == 1) else { return }
            seen.insert(c2); wrong.append(c2)
        }
        for (i, c) in right.enumerated() { var x = right; x[i] = c + 1; add(x); x[i] = c - 1; add(x) }
        for (i, c) in right.enumerated() { var x = right; x[i] = c + 2; add(x); x[i] = c - 2; add(x) }
        if right.count >= 2 { for i in right.indices { var x = right; x.remove(at: i); add(x) } }
        for k in 2..<max(3, n - 1) { add(right + [k]) }
        guard wrong.count >= count - 1 else { return nil }
        return [parts] + wrong.prefix(count - 1).map { split(word, at: $0) }
    }
}
