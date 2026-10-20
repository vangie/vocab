import Foundation

/// 词汇量测试: yes/no recognition over frequency bands with pseudowords to correct for guessing.
public struct VocabBand: Equatable, Sendable, Codable {
    public var lo: Int, hi: Int
    /// Base forms in the extract that fall in this band (the band's weight in the estimate).
    public var size: Int
    public var title: String { lo == 1 ? "前 \(hi)" : "\(lo)–\(hi)" }
}

public struct VocabTestItem: Equatable, Sendable, Codable {
    public var word: String
    /// nil = pseudoword.
    public var band: Int?
    public var known: Bool? = nil
}

public struct BandScore: Equatable, Sendable, Codable {
    public var band: Int
    public var asked: Int
    public var yes: Int
    public var hitRate: Double
    /// Hit rate corrected for false alarms (Huibregtse et al. 2002, I_SDT).
    public var corrected: Double
}

public struct VocabTestResult: Equatable, Sendable, Codable {
    public var date: Date
    public var estimate: Int
    public var low: Int
    public var high: Int
    public var falseAlarm: Double
    public var bands: [BandScore]
    public var bandRanges: [VocabBand]
    /// Bands treated as known (corrected ≥ 0.9): bulk 斩.
    public var knownBands: [Int]
    /// Bands that get a quick 认识吗 check when their words first come up in the plan.
    public var checkBands: [Int]
}

public enum VocabTestScoring {
    public static let bounds = [1, 1000, 2000, 3000, 4000, 5000, 6000, 8000, 10000, 14000, 20000]
    public static let knownThreshold = 0.9
    public static let checkRange = 0.3..<0.9

    /// I_SDT (Huibregtse, Admiraal & Meara 2002): 1 − (4h(1−f) − 2(h−f)(1+h−f)) / (4h(1−f) − (h−f)(1+h−f)).
    public static func isdt(hit h: Double, falseAlarm f: Double) -> Double {
        if h <= f || h <= 0 { return 0 }
        if f >= 1 { return 0 }
        if h >= 1 && f <= 0 { return 1 }
        let num = 4 * h * (1 - f) - 2 * (h - f) * (1 + h - f)
        let den = 4 * h * (1 - f) - (h - f) * (1 + h - f)
        guard den > 0 else { return 0 }
        return min(1, max(0, 1 - num / den))
    }

    /// Corrected rate: I_SDT shrinks toward chance the more pseudowords were claimed; with no false alarms the raw rate stands.
    public static func corrected(hit h: Double, falseAlarm f: Double) -> Double {
        if f <= 0 { return h }
        return min(h, isdt(hit: h, falseAlarm: f))
    }

    public static func score(_ items: [VocabTestItem], bands: [VocabBand], date: Date = Date()) -> VocabTestResult {
        let pseudo = items.filter { $0.band == nil && $0.known != nil }
        let fa = pseudo.isEmpty ? 0 : Double(pseudo.filter { $0.known == true }.count) / Double(pseudo.count)
        var scores: [BandScore] = []
        var est = 0.0, variance = 0.0
        for (i, b) in bands.enumerated() {
            let ans = items.filter { $0.band == i && $0.known != nil }
            let yes = ans.filter { $0.known == true }.count
            // Unasked bands: carry the nearest lower band's rate (bands are monotone in practice).
            let h = ans.isEmpty ? (scores.last?.hitRate ?? 0) : Double(yes) / Double(ans.count)
            let c = corrected(hit: h, falseAlarm: fa)
            scores.append(BandScore(band: i, asked: ans.count, yes: yes, hitRate: h, corrected: c))
            est += c * Double(b.size)
            let n = Double(max(1, ans.count))
            // Wilson-ish floor so 0/4 or 4/4 still carry uncertainty.
            let p = min(max(c, 0.5 / n), 1 - 0.5 / n)
            variance += p * (1 - p) / n * Double(b.size) * Double(b.size)
        }
        let sd = variance.squareRoot()
        let total = bands.reduce(0) { $0 + $1.size }
        let known = scores.filter { $0.corrected >= knownThreshold && $0.asked > 0 }.map(\.band)
        let check = scores.filter { checkRange.contains($0.corrected) && $0.asked > 0 }.map(\.band)
        return VocabTestResult(date: date, estimate: Int(est.rounded()), low: max(0, Int((est - 1.96 * sd).rounded())),
                               high: min(total, Int((est + 1.96 * sd).rounded())), falseAlarm: fa, bands: scores,
                               bandRanges: bands, knownBands: known, checkBands: check)
    }

    /// Bands for round 2: the 2–3 bands where recognition falls through the middle (closest to 50%,
    /// preferring where the drop from the band before is steepest).
    public static func focusBands(_ items: [VocabTestItem], bandCount: Int) -> [Int] {
        var rate: [Int: Double] = [:]
        for i in 0..<bandCount {
            let a = items.filter { $0.band == i && $0.known != nil }
            if !a.isEmpty { rate[i] = Double(a.filter { $0.known == true }.count) / Double(a.count) }
        }
        let ranked = rate.keys.sorted { a, b in
            func cost(_ i: Int) -> Double {
                let drop = (rate[i - 1] ?? 1) - rate[i]!
                return abs(rate[i]! - 0.5) - 0.3 * drop
            }
            return cost(a) != cost(b) ? cost(a) < cost(b) : a < b
        }
        let mids = ranked.filter { (0.05...0.95).contains(rate[$0]!) }
        let pick = (mids.isEmpty ? ranked : mids).prefix(3)
        return pick.count >= 2 ? Array(pick).sorted() : Array(ranked.prefix(2)).sorted()
    }
}

/// Runs a test: round 1 = 4 words per band, round 2 = ~10 more in the focus bands, ~15% pseudowords.
public struct VocabTestRun: Sendable {
    public let bands: [VocabBand]
    private let pool: [[String]]
    private var pseudo: [String]
    public private(set) var items: [VocabTestItem] = []
    public private(set) var index = 0
    public private(set) var round = 1
    public static let perBand = 4
    public static let round2 = 10
    public static let pseudoShare = 0.15

    public init<R: RandomNumberGenerator>(lists: WordLists, using rng: inout R) {
        var bands: [VocabBand] = []; var pool: [[String]] = []
        let b = VocabTestScoring.bounds
        for i in 0..<(b.count - 1) {
            let lo = i == 0 ? 1 : b[i] + 1, hi = b[i + 1]
            let ws = lists.lemmas(rank: lo, hi).filter { $0.count >= 3 }
            bands.append(VocabBand(lo: lo, hi: hi, size: ws.count)); pool.append(ws.shuffled(using: &rng))
        }
        self.init(bands: bands, pool: pool, pseudo: lists.pseudowords().shuffled(using: &rng), using: &rng)
    }

    public init<R: RandomNumberGenerator>(bands: [VocabBand], pool: [[String]], pseudo: [String], using rng: inout R) {
        self.bands = bands; self.pool = pool; self.pseudo = pseudo
        var real: [VocabTestItem] = []
        for i in bands.indices { real += pool[i].prefix(Self.perBand).map { VocabTestItem(word: $0, band: i) } }
        items = Self.withPseudo(real, &self.pseudo, using: &rng)
    }

    static func withPseudo<R: RandomNumberGenerator>(_ real: [VocabTestItem], _ pseudo: inout [String], using rng: inout R) -> [VocabTestItem] {
        let n = Int((Double(real.count) * pseudoShare / (1 - pseudoShare)).rounded())
        let ps = pseudo.prefix(n).map { VocabTestItem(word: $0, band: nil) }
        pseudo.removeFirst(min(n, pseudo.count))
        return (real + ps).shuffled(using: &rng)
    }

    public var current: VocabTestItem? { index < items.count ? items[index] : nil }
    public var finished: Bool { current == nil }
    public var answered: Int { index }

    public mutating func answer(_ known: Bool) {
        guard index < items.count else { return }
        items[index].known = known; index += 1
    }

    public mutating func undo() { if index > 0 { index -= 1; items[index].known = nil } }

    /// After round 1: append round 2. Returns false when there's nothing to add.
    @discardableResult
    public mutating func startRound2<R: RandomNumberGenerator>(using rng: inout R) -> Bool {
        guard round == 1, finished else { return false }
        round = 2
        let focus = VocabTestScoring.focusBands(items, bandCount: bands.count)
        guard !focus.isEmpty else { return false }
        var real: [VocabTestItem] = []
        var k = 0
        while real.count < Self.round2 {
            var added = false
            for b in focus where real.count < Self.round2 {
                let idx = Self.perBand + k
                if idx < pool[b].count { real.append(VocabTestItem(word: pool[b][idx], band: b)); added = true }
            }
            if !added { break }
            k += 1
        }
        items += Self.withPseudo(real, &pseudo, using: &rng)
        return true
    }

    public func result(date: Date = Date()) -> VocabTestResult { VocabTestScoring.score(items, bands: bands, date: date) }
}
