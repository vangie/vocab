import Foundation

/// Adaptive yes/no size test over frequency rank (shared by 词汇量 and 识字量), Rasch / 1PL IRT.
///
/// Item difficulty from frequency: b = k · (ln rank − ln r₀) (k = 3 logits per e-fold of rank,
/// r₀ = 3000 for English / 1500 for characters, so θ = 0 means "recognition drops through 50% at r₀").
/// P(认识 | θ, b) = γ + (1 − γ − λ) · σ(θ − b), γ/λ = 2%/3% absorb lucky yeses and slips.
/// θ is estimated by EAP on a grid (prior N(0, 2²)); the next item is the unused one whose b is
/// nearest θ̂ (maximum information for Rasch). Stop when SE(θ) < 0.35 after ≥ 15 items, or at 40.
/// Size = Σ over candidate items of σ(θ − bᵢ); the interval uses θ ± 1.96·SE.
public enum Adaptive {
    public static let guess = 0.02, lapse = 0.03
    public static let k = 3.0
    public static let minItems = 15, maxItems = 40
    public static let seTarget = 0.35
    static let grid: [Double] = stride(from: -10.0, through: 10.0, by: 0.02).map { $0 }

    public struct Fit: Equatable, Sendable {
        /// θ̂ (EAP) and its posterior SD.
        public var theta: Double, se: Double
        /// Reference ln-rank (θ = 0 ↔ 50% at this rank).
        public var x0: Double
        /// The 50% rank.
        public var threshold: Double { exp(x0 + theta / Adaptive.k) }
        public var mu: Double { x0 + theta / Adaptive.k }
        public var slope: Double { Adaptive.k }
        public var sdMu: Double { se / Adaptive.k }
    }

    @inline(__always) public static func sigma(_ x: Double, mu: Double, s: Double) -> Double { 1 / (1 + exp(s * (x - mu))) }
    @inline(__always) static func difficulty(_ x: Double, x0: Double) -> Double { k * (x - x0) }
    static func pResp(theta: Double, b: Double) -> Double { guess + (1 - guess - lapse) / (1 + exp(b - theta)) }

    /// EAP over θ. Observations: x = ln rank, y ∈ [0, 1] (soft labels allowed).
    public static func fit(_ obs: [(x: Double, y: Double)], x0: Double) -> Fit {
        var logp = grid.map { -$0 * $0 / (2 * 4.0) }
        for o in obs {
            let b = difficulty(o.x, x0: x0)
            for i in grid.indices {
                let p = pResp(theta: grid[i], b: b)
                logp[i] += o.y * log(p) + (1 - o.y) * log(1 - p)
            }
        }
        let m = logp.max()!
        var z = 0.0, m1 = 0.0, m2 = 0.0
        for i in grid.indices { let w = exp(logp[i] - m); z += w; m1 += w * grid[i]; m2 += w * grid[i] * grid[i] }
        let mean = m1 / z
        return Fit(theta: mean, se: max(0, m2 / z - mean * mean).squareRoot(), x0: x0)
    }

    /// Expected number of known items among `ranks`, with an optional per-item correction.
    public static func expected(_ ranks: [Int], mu: Double, s: Double, correct: (Double) -> Double = { $0 }) -> Double {
        ranks.reduce(0) { $0 + correct(sigma(log(Double(max(1, $1))), mu: mu, s: s)) }
    }

    /// Next target ln-rank: where b = θ̂ (start at x0 before any answer).
    public static func nextTarget(fit: Fit?, x0: Double, xMax: Double) -> Double {
        guard let f = fit else { return x0 }
        return min(xMax, max(0, f.mu))
    }

    public static func shouldStop(fit: Fit?, answered: Int) -> Bool {
        if answered >= maxItems { return true }
        guard let f = fit, answered >= minItems else { return false }
        return f.se < seTarget
    }

    /// Mild pseudo-item correction: the false-alarm rate is shrunk toward 0 (as if 2 extra rejected
    /// pseudo-items had been seen) before the correction for guessing P' = (P − f)/(1 − f).
    public static func shrunkFalseAlarm(yes: Int, of n: Int) -> Double { n == 0 ? 0 : Double(yes) / Double(n + 2) }

    /// Answer reliability from pseudo-items: 0 good, 1 fair, 2 low.
    public static func reliability(falseAlarm f: Double, pseudoSeen n: Int) -> Int {
        guard n >= 3 else { return 0 }
        return f <= 0.1 ? 0 : f <= 0.25 ? 1 : 2
    }

    /// Wang Xiaoling-style stratified cross-check: Σ band size × (yes rate in band), unasked bands
    /// interpolated from neighbours (1 below the first asked, 0 above the last).
    public static func stratified(_ bands: [VocabBand], asked: [Int: (Int, Int)]) -> Int {
        let rates: [Double?] = bands.indices.map { i in asked[i].flatMap { $0.0 > 0 ? Double($0.1) / Double($0.0) : nil } }
        var total = 0.0
        for i in bands.indices {
            var r = rates[i]
            if r == nil {
                let lo = (0..<i).reversed().first { rates[$0] != nil }.flatMap { rates[$0] } ?? 1
                let hi = ((i + 1)..<bands.count).first { rates[$0] != nil }.flatMap { rates[$0] } ?? 0
                r = (lo + hi) / 2
            }
            total += r! * Double(bands[i].size)
        }
        return Int(total.rounded())
    }

    /// 「约 8,200（7,400–9,100）」: 2–3 significant figures.
    public static func roundSize(_ n: Int) -> Int {
        n >= 10000 ? (n + 50) / 100 * 100 : n >= 1000 ? (n + 50) / 100 * 100 : n >= 100 ? (n + 5) / 10 * 10 : n
    }
    public static func sizeText(_ e: Int, _ lo: Int, _ hi: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US")
        func s(_ n: Int) -> String { f.string(from: NSNumber(value: roundSize(n))) ?? "\(n)" }
        return "约 \(s(e))（\(s(lo))–\(s(hi))）"
    }

    /// Index into `xs` (sorted ascending) of the unused item nearest `target`.
    /// Small seedable generator stored in a test run, so each run varies but tests stay reproducible.
    public struct Gen: RandomNumberGenerator, Sendable {
        var s: UInt64
        public init(seed: UInt64) { s = seed }
        public init<R: RandomNumberGenerator>(from r: inout R) { s = r.next() }
        public mutating func next() -> UInt64 {
            s &+= 0x9E3779B97F4A7C15
            var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// Start-point jitter (log-rank) so runs don't open with the same items.
    public static let startJitter = 0.3
    /// Items are drawn at random from those within this log-rank distance of the target (≈ ±8% rank);
    /// Rasch information is nearly flat that close to θ̂, so accuracy is unaffected.
    public static let window = 0.08

    /// Random unused index with |x − target| ≤ window, else the nearest unused one.
    public static func pick<R: RandomNumberGenerator>(_ target: Double, in xs: [Double], used: Set<Int>,
                                                      allowed: (Int) -> Bool = { _ in true }, using rng: inout R) -> Int? {
        guard !xs.isEmpty else { return nil }
        var lo = 0, hi = xs.count
        while lo < hi { let m = (lo + hi) / 2; if xs[m] < target - window { lo = m + 1 } else { hi = m } }
        var cands: [Int] = []
        var i = lo
        while i < xs.count, xs[i] <= target + window { if !used.contains(i) && allowed(i) { cands.append(i) }; i += 1 }
        if let c = cands.randomElement(using: &rng) { return c }
        var u = used
        while let j = nearest(target, in: xs, used: u) { if allowed(j) { return j }; u.insert(j) }
        return nil
    }

    /// Real-item counts after which a pseudo-item is shown: random gaps of 4…8 (mean 6).
    public static func pseudoSchedule<R: RandomNumberGenerator>(using rng: inout R) -> Set<Int> {
        var out = Set<Int>(), n = Int.random(in: 3...7, using: &rng)
        while n < 200 { out.insert(n); n += Int.random(in: 4...8, using: &rng) }
        return out
    }

    public static func nearest(_ target: Double, in xs: [Double], used: Set<Int>) -> Int? {
        guard !xs.isEmpty else { return nil }
        var lo = 0, hi = xs.count
        while lo < hi { let m = (lo + hi) / 2; if xs[m] < target { lo = m + 1 } else { hi = m } }
        var l = lo - 1, r = lo
        while l >= 0 || r < xs.count {
            let dl = l >= 0 ? target - xs[l] : .infinity, dr = r < xs.count ? xs[r] - target : .infinity
            if dl <= dr { if !used.contains(l) { return l }; l -= 1 } else { if !used.contains(r) { return r }; r += 1 }
        }
        return nil
    }

    /// Per-band summary rows for the result (plan uses knownBands / checkBands).
    static func bands(_ bands: [VocabBand], ranksByBand: [[Int]], asked: [Int: (Int, Int)], value: (Int) -> Double) -> [BandScore] {
        bands.indices.map { i in
            let rs = ranksByBand[i]
            let c = rs.isEmpty ? 0 : rs.reduce(0) { $0 + value($1) } / Double(rs.count)
            let a = asked[i] ?? (0, 0)
            return BandScore(band: i, asked: a.0, yes: a.1, hitRate: a.0 > 0 ? Double(a.1) / Double(a.0) : c, corrected: c)
        }
    }
}
