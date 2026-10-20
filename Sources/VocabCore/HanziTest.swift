import Foundation

/// 识字量测试 data: Jun Da's Modern Chinese Character Frequency List (GB2312 subset, rank order),
/// with CEDICT readings. Built by scripts/build-hanzi.py into Resources/Data/hanzi-freq.tsv.
public struct HanziList: Sendable {
    public struct Char: Equatable, Sendable {
        public var char: String
        public var readings: [String]
        /// Kangxi radical number (Unihan kRSUnicode), 0 = unknown.
        public var radical: Int = 0
        /// Short English gloss (CEDICT), fallback for the meaning check.
        public var gloss: String = ""
        public init(char: String, readings: [String], radical: Int = 0, gloss: String = "") {
            self.char = char; self.readings = readings; self.radical = radical; self.gloss = gloss
        }
    }
    public let chars: [Char]

    public init(chars: [Char]) { self.chars = chars }

    public init?(tsv: String) {
        var out: [Char] = []
        for line in tsv.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 2, !f[0].isEmpty else { continue }
            out.append(Char(char: String(f[0]), readings: f[1].split(separator: "/").map(String.init),
                            radical: f.count > 2 ? Int(f[2]) ?? 0 : 0, gloss: f.count > 3 ? String(f[3]) : ""))
        }
        guard !out.isEmpty else { return nil }
        chars = out
    }

    public static func bundledURL() -> URL? {
        if let u = Bundle.main.url(forResource: "hanzi-freq", withExtension: "tsv") { return u }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Data/hanzi-freq.tsv")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }

    public static let shared: HanziList? = bundledURL().flatMap { try? String(contentsOf: $0, encoding: .utf8) }.flatMap(HanziList.init(tsv:))
}

/// Pinyin helpers for the reading check.
public enum Pinyin {
    static let marks: [Character: (Character, Int)] = {
        var m: [Character: (Character, Int)] = [:]
        for (base, s) in [("a", "āáǎà"), ("e", "ēéěè"), ("i", "īíǐì"), ("o", "ōóǒò"), ("u", "ūúǔù"), ("ü", "ǖǘǚǜ")] {
            for (i, c) in s.enumerated() { m[c] = (Character(base), i + 1) }
        }
        return m
    }()

    /// ("hǎo") → ("hao", 3); neutral tone = 5.
    public static func split(_ p: String) -> (base: String, tone: Int) {
        var base = "", tone = 5
        for c in p { if let (b, t) = marks[c] { base.append(b); tone = t } else { base.append(c) } }
        return (base, tone)
    }

    /// Put tone 1–4 (or 5 = none) on a toneless syllable, using the standard placement rule.
    public static func apply(_ base: String, tone: Int) -> String {
        guard (1...4).contains(tone) else { return base }
        let table: [Character: String] = ["a": "āáǎà", "e": "ēéěè", "i": "īíǐì", "o": "ōóǒò", "u": "ūúǔù", "ü": "ǖǘǚǜ"]
        var cs = Array(base)
        func put(_ i: Int) -> String { cs[i] = Array(table[cs[i]]!)[tone - 1]; return String(cs) }
        if let i = cs.firstIndex(where: { $0 == "a" || $0 == "e" }) { return put(i) }
        if let r = base.range(of: "ou") { return put(base.distance(from: base.startIndex, to: r.lowerBound)) }
        if let i = cs.lastIndex(where: { table[$0] != nil }) { return put(i) }
        return base
    }
}

public struct HanziTestItem: Equatable, Sendable {
    public var char: String
    public var readings: [String]
    public var band: Int
    /// Spot-check this item when answered 认识.
    public var check: Bool
    public enum CheckKind: Equatable, Sendable { case reading, meaning }
    public var checkKind: CheckKind = .reading
    public var choices: [String] = []
    /// Accepted answers (all readings for a reading check; the one gloss for a meaning check).
    public var correct: Set<String> = []
    public var known: Bool? = nil
    /// Spot-check outcome (nil = not asked). A failed check discounts the 认识 claim.
    public var checkCorrect: Bool? = nil
}

public enum HanziTestScoring {
    public static let bounds = [1, 500, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 5000]

    /// Share of 认识 claims that the reading check confirms, corrected for 1-in-4 guessing.
    /// `prior` pseudo-counts of correct answers keep a single slip from halving the estimate.
    public static func verified(correct c: Int, of n: Int, prior: Double = 1) -> Double {
        guard n > 0 else { return 1 }
        let acc = (Double(c) + prior) / (Double(n) + prior)
        return min(1, max(0, (acc - 0.25) / 0.75))
    }

    public static func bands(total: Int) -> [VocabBand] {
        var out: [VocabBand] = []
        let b = bounds + [total]
        for i in 0..<(b.count - 1) where b[i + 1] > b[i] {
            let lo = i == 0 ? 1 : b[i] + 1, hi = b[i + 1]
            out.append(VocabBand(lo: lo, hi: hi, size: hi - lo + 1))
        }
        return out
    }

    /// Estimate = Σ band size × yes rate × verified share. The verified share is the band's own
    /// when it has ≥ 2 reading checks, else pooled over all bands. Reuses VocabTestResult;
    /// `falseAlarm` holds the overall overclaim rate (1 − pooled verified share).
    public static func score(_ items: [HanziTestItem], bands: [VocabBand], date: Date = Date()) -> VocabTestResult {
        let checked = items.filter { $0.checkCorrect != nil }
        let pooled = verified(correct: checked.filter { $0.checkCorrect == true }.count, of: checked.count)
        var scores: [BandScore] = []
        var est = 0.0, variance = 0.0
        for (i, b) in bands.enumerated() {
            let ans = items.filter { $0.band == i && $0.known != nil }
            let yes = ans.filter { $0.known == true }.count
            let h = ans.isEmpty ? (scores.last?.hitRate ?? 0) : Double(yes) / Double(ans.count)
            let bc = checked.filter { $0.band == i }
            let v = bc.count >= 2 ? verified(correct: bc.filter { $0.checkCorrect == true }.count, of: bc.count) : pooled
            let c = h * v
            scores.append(BandScore(band: i, asked: ans.count, yes: yes, hitRate: h, corrected: c))
            est += c * Double(b.size)
            let n = Double(max(1, ans.count))
            let p = min(max(c, 0.5 / n), 1 - 0.5 / n)
            variance += p * (1 - p) / n * Double(b.size) * Double(b.size)
        }
        let sd = variance.squareRoot()
        let total = bands.reduce(0) { $0 + $1.size }
        return VocabTestResult(date: date, estimate: Int(est.rounded()), low: max(0, Int((est - 1.96 * sd).rounded())),
                               high: min(total, Int((est + 1.96 * sd).rounded())), falseAlarm: 1 - pooled,
                               bands: scores, bandRanges: bands, knownBands: [], checkBands: [])
    }
}

/// Chinese glosses for the meaning check, read from an installed dictionary's plain text
/// (现代汉语规范词典 «① 形 亮（跟“暗”相对）。…», or 新华字典 «基本解释 1 亮，…»).
public enum HanziGloss {
    /// First sense, ≤ 18 characters, with the character itself masked as ～ (so it can't give the answer away).
    public static func firstSense(_ text: String, char: String) -> String? {
        var t = text
        if let r = t.range(of: "基本解释") { t = String(t[r.upperBound...]) }
        else if let r = t.range(of: "①") { t = String(t[r.upperBound...]) }
        else {
            // Single-sense 规范 entry: «鸳 yuān （鴛）名 指鸳鸯。…» — skip headword and reading.
            let parts = t.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3 else { return nil }
            t = String(parts[2])
        }
        t = t.replacingOccurrences(of: #"[①-⑳]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^\s*[0-9０-９]+\s*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^\s*(（[^）]*）\s*)+"#, with: "", options: .regularExpression)       // （鴛）
        t = t.replacingOccurrences(of: #"〔[^〕]*〕"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^\s*(拟声|[形动名助副量代介连叹数])\s+"#, with: "", options: .regularExpression)   // POS
        t = t.replacingOccurrences(of: #"\s*〈[^〉]*〉\s*"#, with: "", options: .regularExpression)
        if let end = t.firstIndex(where: { "。：；|\n".contains($0) }) { t = String(t[..<end]) }
        t = t.replacingOccurrences(of: char, with: "～").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "，、,.")))
        guard t.count >= 1, t.range(of: #"\p{Han}"#, options: .regularExpression) != nil else { return nil }
        // Not a meaning: cross-references (见…, 同“…”, 古同…), compounds (～础, 跳～), pinyin.
        if t.hasPrefix("见") || t.hasPrefix("同“") || t.hasPrefix("古同") || t.hasPrefix("～")
            || (t.contains("～") && t.count <= 4) || t.range(of: #"[a-zA-Zāáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜü]"#, options: .regularExpression) != nil {
            return nil
        }
        if t.count > 18 { t = String(t.prefix(18)) + "…" }
        return t
    }
}

/// Round 1 = 4 characters per band; round 2 = 10 more in the bands where recognition drops through
/// 50%. Every third character (and every round-2 one) answered 认识 gets a spot-check that
/// alternates between its reading (4 pinyin) and its meaning (4 glosses; distractors are glosses of
/// characters with the same radical, i.e. look-alikes). A failed check discounts the claim.
public struct HanziTestRun: Sendable {
    public typealias Glosser = @Sendable (HanziList.Char) -> String?
    public let bands: [VocabBand]
    private let pool: [[HanziList.Char]]
    private let list: [HanziList.Char]
    private let byRadical: [Int: [Int]]
    private let allReadings: [String]
    private let gloss: Glosser
    private var checks = 0
    public private(set) var items: [HanziTestItem] = []
    public private(set) var index = 0
    public private(set) var round = 1
    /// True while the current item waits for its spot-check answer.
    public private(set) var askingCheck = false
    public static let perBand = 4
    public static let round2 = 10

    /// `gloss` defaults to the bundled English gloss; the app passes Chinese glosses from 规范/新华.
    public init<R: RandomNumberGenerator>(list: HanziList, gloss: Glosser? = nil, using rng: inout R) {
        let bands = HanziTestScoring.bands(total: list.chars.count)
        var pool: [[HanziList.Char]] = []
        for b in bands { pool.append(Array(list.chars[(b.lo - 1)..<b.hi]).filter { !$0.readings.isEmpty }.shuffled(using: &rng)) }
        self.bands = bands; self.pool = pool; self.list = list.chars
        var rad: [Int: [Int]] = [:]
        for (i, c) in list.chars.enumerated() where c.radical > 0 { rad[c.radical, default: []].append(i) }
        byRadical = rad
        allReadings = Array(Set(list.chars.flatMap(\.readings))).sorted()
        self.gloss = gloss ?? { $0.gloss.isEmpty ? nil : $0.gloss }
        var real: [HanziTestItem] = []
        var k = 0
        for i in bands.indices {
            for c in pool[i].prefix(Self.perBand) { real.append(makeItem(c, band: i, check: k % 3 == 0, using: &rng)); k += 1 }
        }
        items = real.shuffled(using: &rng)
    }

    private mutating func makeItem<R: RandomNumberGenerator>(_ c: HanziList.Char, band: Int, check: Bool, using rng: inout R) -> HanziTestItem {
        var it = HanziTestItem(char: c.char, readings: c.readings, band: band, check: check)
        guard check else { return it }
        let wantMeaning = checks % 2 == 1
        checks += 1
        if wantMeaning, let m = meaningChoices(for: c, using: &rng) {
            it.checkKind = .meaning; it.choices = m.choices; it.correct = [m.right]
        } else {
            it.checkKind = .reading; it.choices = Self.choices(for: c.readings, all: allReadings, using: &rng); it.correct = Set(c.readings)
        }
        return it
    }

    /// Right gloss + 3 glosses of same-radical characters (nearest in frequency first), else any.
    func meaningChoices<R: RandomNumberGenerator>(for c: HanziList.Char, using rng: inout R) -> (right: String, choices: [String])? {
        guard let right = gloss(c) else { return nil }
        let rank = list.firstIndex(of: c) ?? 0
        var cands = (byRadical[c.radical] ?? []).filter { list[$0].char != c.char }
            .sorted { abs($0 - rank) < abs($1 - rank) }.prefix(12).shuffled(using: &rng)
        cands += (0..<list.count).shuffled(using: &rng).prefix(30)
        var out = [right]
        for i in cands where out.count < 4 {
            if let g = gloss(list[i]), !out.contains(g), !g.isEmpty { out.append(g) }
        }
        return out.count == 4 ? (right, out.shuffled(using: &rng)) : nil
    }

    /// The first reading plus 3 distractors that are none of the character's readings:
    /// one same syllable with another tone when possible, the rest other syllables.
    public static func choices<R: RandomNumberGenerator>(for readings: [String], all: [String], using rng: inout R) -> [String] {
        guard let right = readings.first else { return [] }
        let own = Set(readings)
        var out = [right]
        let (base, tone) = Pinyin.split(right)
        if let t = [1, 2, 3, 4].filter({ $0 != tone }).shuffled(using: &rng).first(where: { !own.contains(Pinyin.apply(base, tone: $0)) }) {
            out.append(Pinyin.apply(base, tone: t))
        }
        let bases = Set(readings.map { Pinyin.split($0).base })
        for r in all.shuffled(using: &rng) where out.count < 4 {
            if !own.contains(r) && !out.contains(r) && !bases.contains(Pinyin.split(r).base) { out.append(r) }
        }
        return out.shuffled(using: &rng)
    }

    public var current: HanziTestItem? { index < items.count ? items[index] : nil }
    public var finished: Bool { current == nil }
    public var answered: Int { index }

    public mutating func answer(_ known: Bool) {
        guard index < items.count, !askingCheck else { return }
        items[index].known = known
        if known && items[index].check && !items[index].choices.isEmpty { askingCheck = true } else { index += 1 }
    }

    /// Answer the spot-check ("" = 不确定, counts as failed).
    public mutating func answerCheck(_ choice: String) {
        guard askingCheck, index < items.count else { return }
        items[index].checkCorrect = items[index].correct.contains(choice)
        askingCheck = false; index += 1
    }

    public mutating func undo() {
        if askingCheck { askingCheck = false; items[index].known = nil; return }
        if index > 0 { index -= 1; items[index].known = nil; items[index].checkCorrect = nil }
    }

    @discardableResult
    public mutating func startRound2<R: RandomNumberGenerator>(using rng: inout R) -> Bool {
        guard round == 1, finished else { return false }
        round = 2
        let asItems = items.map { VocabTestItem(word: $0.char, band: $0.band, known: $0.known) }
        let focus = VocabTestScoring.focusBands(asItems, bandCount: bands.count)
        guard !focus.isEmpty else { return false }
        var real: [HanziTestItem] = []
        var k = 0
        while real.count < Self.round2 {
            var added = false
            for b in focus where real.count < Self.round2 {
                let idx = Self.perBand + k
                if idx < pool[b].count { real.append(makeItem(pool[b][idx], band: b, check: true, using: &rng)); added = true }
            }
            if !added { break }
            k += 1
        }
        guard !real.isEmpty else { return false }
        items += real.shuffled(using: &rng)
        return true
    }

    public func result(date: Date = Date()) -> VocabTestResult { HanziTestScoring.score(items, bands: bands, date: date) }
}
