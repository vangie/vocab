import Foundation

/// Adaptive yes/no size test over frequency rank (shared by 词汇量 and 识字量).
///
/// Model: P(know | rank r) = γ + (1 − γ − λ) · σ(−s · (ln r − μ)), a logistic in log-rank with
/// threshold e^μ (the rank where recognition drops through 50%) and slope s; γ/λ absorb the odd
/// lucky yes / slip. μ and s are fitted by grid posterior (weak priors) after every answer.
/// Selection: a ×2 / ÷2 staircase from the start rank until the first reversal, then items around
/// the fitted threshold (alternating just below / above it, which also pins the slope).
/// Stop: ≥ minItems and the estimate moved < 4% over the last 8 answers, or maxItems.
/// Estimate: Σ over the candidate items of σ(…) at their rank (corrected by the caller).
public enum Adaptive {
    public static let guess = 0.02, lapse = 0.03
    public static let slopes: [Double] = [1, 1.5, 2, 2.5, 3, 4, 5, 7]
    public static let minItems = 24, maxItems = 40
    static let offsets: [Double] = [0, -0.4, 0.4, -0.2, 0.2]

    public struct Fit: Equatable, Sendable {
        public var mu: Double, slope: Double, sdMu: Double
        public var threshold: Double { exp(mu) }
    }

    @inline(__always) public static func sigma(_ x: Double, mu: Double, s: Double) -> Double { 1 / (1 + exp(s * (x - mu))) }
    static func pResp(_ x: Double, mu: Double, s: Double) -> Double { guess + (1 - guess - lapse) * sigma(x, mu: mu, s: s) }

    /// Observations: x = ln rank, y ∈ [0, 1] (soft labels allowed: a partly verified 认识).
    public static func fit(_ obs: [(x: Double, y: Double)], xMax: Double) -> Fit {
        let mus = stride(from: -0.5, through: xMax + 1.0, by: 0.025).map { $0 }
        let priorMu = xMax * 0.6, priorSD = 2.5
        var post = [[Double]](repeating: [Double](repeating: 0, count: slopes.count), count: mus.count)
        var best = -Double.infinity
        for (i, mu) in mus.enumerated() {
            for (j, s) in slopes.enumerated() {
                var ll = -pow(mu - priorMu, 2) / (2 * priorSD * priorSD) - pow(log(s / 2.5), 2) / (2 * 0.5 * 0.5)
                for o in obs {
                    let p = pResp(o.x, mu: mu, s: s)
                    ll += o.y * log(p) + (1 - o.y) * log(1 - p)
                }
                post[i][j] = ll; best = max(best, ll)
            }
        }
        var z = 0.0, m1 = 0.0, m2 = 0.0
        var sw = [Double](repeating: 0, count: slopes.count)
        for i in mus.indices {
            for j in slopes.indices {
                let w = exp(post[i][j] - best)
                z += w; m1 += w * mus[i]; m2 += w * mus[i] * mus[i]; sw[j] += w
            }
        }
        let mean = m1 / z
        let sd = max(0, m2 / z - mean * mean).squareRoot()
        let s = slopes[sw.indices.max { sw[$0] < sw[$1] }!]
        return Fit(mu: mean, slope: s, sdMu: sd)
    }

    /// Expected number of known items among `ranks` under the fit, with an optional per-item correction.
    public static func expected(_ ranks: [Int], mu: Double, s: Double, correct: (Double) -> Double = { $0 }) -> Double {
        ranks.reduce(0) { $0 + correct(sigma(log(Double(max(1, $1))), mu: mu, s: s)) }
    }

    /// Next target ln-rank. `history` = answered real items in order (x, said known).
    public static func nextTarget(history: [(x: Double, known: Bool)], fit: Fit?, startX: Double, xMax: Double) -> Double {
        guard let last = history.last else { return startX }
        let reversed = history.contains { $0.known != history[0].known }
        if !reversed || fit == nil {
            return min(xMax, max(0, last.x + (last.known ? log(2.0) : -log(2.0))))
        }
        let k = history.count
        let off = offsets[k % offsets.count] * (2.5 / fit!.slope)
        return min(xMax, max(0, fit!.mu + off))
    }

    /// Converged: enough items and the estimate stable (±5%) over the last 6 answers.
    public static func shouldStop(estimates: [Double], answered: Int) -> Bool {
        if answered >= maxItems { return true }
        guard answered >= minItems, estimates.count >= 8 else { return false }
        let tail = estimates.suffix(8)
        let hi = tail.max()!, lo = tail.min()!
        return hi - lo <= 0.04 * max(hi, 50)
    }

    /// Index into `xs` (sorted ascending) of the unused item nearest `target`.
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
