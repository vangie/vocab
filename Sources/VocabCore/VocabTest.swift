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
    /// Frequency rank (adaptive test); nil for pseudowords and old results.
    public var rank: Int? = nil
    /// 4-choice meaning spot-check when answered 认识 (choices filled in when asked).
    public var check = false
    public var choices: [String] = []
    public var correctChoice: String? = nil
    public var checkCorrect: Bool? = nil
    /// The check was answered 不确定 (counts as failed, but less than a wrong pick).
    public var checkUnsure: Bool? = nil
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
    /// Answer reliability from pseudo-items (0 good, 1 fair, 2 low); nil for old results.
    /// Database row id when loaded from the store (for deletion); not meaningful in the JSON.
    public var rowID: Int64? = nil
    public var reliability: Int? = nil
    /// Stratified (per-band yes-rate) estimate, shown as a cross-check.
    public var crossCheck: Int? = nil
    /// Share of pseudo-items claimed known (raw), when a test had them.
    public var pseudoYes: Double? = nil
    /// Per-item log (word, rank, answer, meaning check) for diagnosis; nil for old results.
    public var items: [VocabTestItem]? = nil
    public var sizeText: String { Adaptive.sizeText(estimate, low, high) }
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

/// Adaptive 词汇量 test (Rasch, see `Adaptive`): θ = 0 at rank 3000, ~14% pseudowords interleaved;
/// a mildly shrunk pseudoword false-alarm rate corrects the curve (P → (P − f)/(1 − f)).
public struct VocabTestRun: Sendable {
    /// Right gloss + 3 distractor glosses for a word (the quiz's confusable-word logic), or nil.
    public typealias MeaningMaker = @Sendable (String) -> (right: String, choices: [String])?
    public var meaning: MeaningMaker? = nil
    public static let checkEvery = 3      // every 3rd real word answered 认识 gets a meaning check
    public private(set) var askingCheck = false
    private var knownClaims = 0
    public let bands: [VocabBand]
    private let words: [String]
    private let ranks: [Int]
    private let xs: [Double]
    private let ranksByBand: [[Int]]
    private var pseudo: [String]
    private var used = Set<Int>()
    private var stopped = false
    private var gen: Adaptive.Gen
    private var startX: Double
    private var pseudoAt: Set<Int>
    public private(set) var items: [VocabTestItem] = []
    public static let startRank = 3000
    public static let pseudoEvery = 6      // one pseudoword after every 6 real words (≈ 14%)

    public init<R: RandomNumberGenerator>(lists: WordLists, avoid: Set<String> = [], using rng: inout R) {
        let b = VocabTestScoring.bounds
        var cands: [(word: String, rank: Int)] = []
        for i in 0..<(b.count - 1) {
            let lo = i == 0 ? 1 : b[i] + 1, hi = b[i + 1]
            cands += lists.lemmasRanked(rank: lo, hi).filter { $0.word.count >= 3 }
        }
        self.init(candidates: cands, pseudo: lists.pseudowords().shuffled(using: &rng), avoid: avoid, using: &rng)
    }

    /// `candidates` sorted by rank (ties shuffled so equal ranks don't repeat a pattern).
    /// `avoid`: words shown in recent runs; skipped while enough other candidates remain.
    public init<R: RandomNumberGenerator>(candidates: [(word: String, rank: Int)], pseudo: [String], avoid: Set<String> = [], using rng: inout R) {
        let c = candidates.shuffled(using: &rng).sorted { $0.rank < $1.rank }
        words = c.map(\.word); ranks = c.map(\.rank); xs = ranks.map { log(Double(max(1, $0))) }
        let b = VocabTestScoring.bounds
        var bands: [VocabBand] = [], byBand: [[Int]] = []
        for i in 0..<(b.count - 1) {
            let lo = i == 0 ? 1 : b[i] + 1, hi = b[i + 1]
            let rs = ranks.filter { (lo...hi).contains($0) }
            bands.append(VocabBand(lo: lo, hi: hi, size: rs.count)); byBand.append(rs)
        }
        self.bands = bands; ranksByBand = byBand
        let lowAvoid = Set(avoid.map { $0.lowercased() })
        self.pseudo = pseudo.filter { !lowAvoid.contains($0.lowercased()) } + pseudo.filter { lowAvoid.contains($0.lowercased()) }
        gen = Adaptive.Gen(from: &rng)
        startX = log(Double(Self.startRank)) + Double.random(in: -Adaptive.startJitter...Adaptive.startJitter, using: &rng)
        pseudoAt = Adaptive.pseudoSchedule(using: &rng)
        if !lowAvoid.isEmpty {
            let hit = words.indices.filter { lowAvoid.contains(words[$0].lowercased()) }
            if hit.count < words.count / 4 { used.formUnion(hit) }
        }
        appendNext()
    }

    private func bandOf(_ rank: Int) -> Int { bands.firstIndex { (($0.lo)...($0.hi)).contains(rank) } ?? bands.count - 1 }
    private var real: [VocabTestItem] { items.filter { $0.band != nil && $0.known != nil } }
    private var xMax: Double { xs.last ?? 10 }

    private func currentFit() -> Adaptive.Fit? {
        let r = real
        guard !r.isEmpty else { return nil }
        return Adaptive.fit(r.map { (log(Double($0.rank ?? 1)), Self.label($0)) }, x0: log(Double(Self.startRank)))
    }

    /// Size-curve ceiling from the meaning checks (see `Adaptive.ceiling`).
    public var ceiling: Double {
        let c = items.filter { $0.checkCorrect != nil }
        return Adaptive.ceiling(passed: c.filter { $0.checkCorrect == true }.count,
                                failed: c.filter { $0.checkCorrect == false && $0.checkUnsure != true }.count,
                                unsure: c.filter { $0.checkUnsure == true }.count)
    }

    /// Share of meaning checks passed, guess-corrected (1 when none asked yet).
    public var verified: Double {
        let c = items.filter { $0.checkCorrect != nil }
        return HanziTestScoring.verified(correct: c.filter { $0.checkCorrect == true }.count, of: c.count)
    }

    static func label(_ it: VocabTestItem) -> Double {
        Adaptive.label(known: it.known, checkCorrect: it.checkCorrect, unsure: it.checkUnsure)
    }

    private mutating func appendNext() {
        let realCount = items.filter { $0.band != nil }.count
        if pseudoAt.contains(realCount), items.last?.band != nil, !pseudo.isEmpty {
            items.append(VocabTestItem(word: pseudo.removeFirst(), band: nil)); return
        }
        let fit = currentFit()
        let target = fit == nil ? startX : Adaptive.nextTarget(fit: fit, x0: log(Double(Self.startRank)), xMax: xMax)
        guard let i = Adaptive.pick(target, in: xs, used: used, using: &gen) else { stopped = true; return }
        used.insert(i)
        items.append(VocabTestItem(word: words[i], band: bandOf(ranks[i]), rank: ranks[i]))
    }

    public var current: VocabTestItem? { items.last.flatMap { $0.known == nil || askingCheck ? $0 : nil } }
    public var finished: Bool { current == nil }
    public var answered: Int { items.filter { $0.known != nil }.count - (askingCheck ? 1 : 0) }
    /// Real (non-pseudo) words answered; the stop rule counts these.
    public var answeredReal: Int { real.count }
    /// Upper bound for the progress bar.
    public var expectedTotal: Int { Int(Double(Adaptive.maxItems) * Double(Self.pseudoEvery + 1) / Double(Self.pseudoEvery)) }

    public mutating func answer(_ known: Bool) {
        guard !askingCheck, let i = items.indices.last, items[i].known == nil else { return }
        items[i].known = known
        if known, items[i].band != nil {
            knownClaims += 1
            if knownClaims % Self.checkEvery == 1, let m = meaning?(items[i].word) {
                items[i].check = true; items[i].choices = m.choices; items[i].correctChoice = m.right
                askingCheck = true; return
            }
        }
        advance()
    }

    /// Answer the meaning check ("" = 不确定, counts as failed).
    public mutating func answerCheck(_ choice: String) {
        guard askingCheck, let i = items.indices.last else { return }
        items[i].checkCorrect = choice == items[i].correctChoice
        items[i].checkUnsure = choice.isEmpty
        askingCheck = false
        advance()
    }

    private mutating func advance() {
        guard let i = items.indices.last else { return }
        if items[i].band != nil && Adaptive.shouldStop(fit: currentFit(), answered: answeredReal) { stopped = true; return }
        appendNext()
    }

    public mutating func undo() {
        if askingCheck, let i = items.indices.last {
            askingCheck = false; items[i].known = nil; items[i].check = false; items[i].choices = []; knownClaims -= 1; return
        }
        if let last = items.last, last.known == nil {
            items.removeLast()
            if let r = last.rank, let i = ranks.indices.first(where: { ranks[$0] == r && words[$0] == last.word }) { used.remove(i) }
            if last.band == nil { pseudo.insert(last.word, at: 0) }
        }
        guard let i = items.indices.last else { appendNext(); return }
        if items[i].known == true, items[i].band != nil { knownClaims -= 1 }
        items[i].known = nil; items[i].checkCorrect = nil; items[i].checkUnsure = nil; items[i].check = false; items[i].choices = []
        stopped = false
    }

    /// Kept for API compatibility: the adaptive test has no second round.
    @discardableResult public mutating func startRound2<R: RandomNumberGenerator>(using rng: inout R) -> Bool { false }
    public var round: Int { 1 }

    public func result(date: Date = Date()) -> VocabTestResult {
        let ps = items.filter { $0.band == nil && $0.known != nil }
        let yes = ps.filter { $0.known == true }.count
        let f = Adaptive.shrunkFalseAlarm(yes: yes, of: ps.count)
        let raw = ps.isEmpty ? 0 : Double(yes) / Double(ps.count)
        let cap = ceiling
        let correct: (Double) -> Double = { p in f >= 1 ? 0 : cap * max(0, (p - f) / (1 - f)) }
        guard let fit = currentFit() else {
            return VocabTestResult(date: date, estimate: 0, low: 0, high: 0, falseAlarm: f, bands: [], bandRanges: bands, knownBands: [], checkBands: [])
        }
        let est = Adaptive.expected(ranks, mu: fit.mu, s: fit.slope, correct: correct)
        let lo = Adaptive.expected(ranks, mu: fit.mu - 1.96 * fit.sdMu, s: fit.slope, correct: correct)
        let hi = Adaptive.expected(ranks, mu: fit.mu + 1.96 * fit.sdMu, s: fit.slope, correct: correct)
        var asked: [Int: (Int, Int)] = [:]
        for it in real { let b = it.band!; let a = asked[b] ?? (0, 0); asked[b] = (a.0 + 1, a.1 + (it.known! ? 1 : 0)) }
        let scores = Adaptive.bands(bands, ranksByBand: ranksByBand, asked: asked) { r in
            correct(Adaptive.sigma(log(Double(max(1, r))), mu: fit.mu, s: fit.slope))
        }
        let known = scores.filter { $0.corrected >= VocabTestScoring.knownThreshold }.map(\.band)
        let check = scores.filter { VocabTestScoring.checkRange.contains($0.corrected) }.map(\.band)
        return VocabTestResult(date: date, estimate: Int(est.rounded()), low: Int(lo.rounded()), high: Int(hi.rounded()),
                               falseAlarm: f, bands: scores, bandRanges: bands, knownBands: known, checkBands: check,
                               reliability: max(Adaptive.reliability(falseAlarm: raw, pseudoSeen: ps.count), cap < 0.8 ? 2 : cap < 0.95 ? 1 : 0),
                               crossCheck: Adaptive.stratified(bands, asked: asked), pseudoYes: raw,
                               items: items.filter { $0.known != nil })
    }
}

/// Easy distractors for the 词汇量 meaning check: glosses of common, unrelated words. The check only
/// confirms that a 认识 is real; telling confusables apart (affect / effect) belongs to study quizzes.
public enum EasyDistractors {
    /// Han characters of a gloss, ignoring punctuation and grammar fillers.
    static func han(_ s: String) -> Set<Character> {
        Set(s.filter { ("\u{4E00}"..."\u{9FFF}").contains(String($0)) && !"的地得了是有一种使把被对与和或".contains($0) })
    }

    /// Three glosses from `pool` (candidate words, e.g. common lemmas) that share no spelling start and
    /// no meaning-bearing character with the right gloss or each other. nil if not enough are found.
    public static func pick<R: RandomNumberGenerator>(word: String, right: String, pool: [String], avoid: Set<String> = [],
                                                      gloss: (String) -> String?, using rng: inout R) -> [String]? {
        let w = word.lowercased()
        var seen = han(right), out: [String] = []
        for cand in pool.shuffled(using: &rng).prefix(60) {
            let c = cand.lowercased()
            guard c != w, !avoid.contains(c), c.prefix(3) != w.prefix(3), !c.contains(w), !w.contains(c) else { continue }
            guard let g = gloss(cand), !g.isEmpty, g != right else { continue }
            let h = han(g)
            guard !h.isEmpty, h.isDisjoint(with: seen) else { continue }
            out.append(g); seen.formUnion(h)
            if out.count == 3 { return out }
        }
        return nil
    }
}
