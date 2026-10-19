import Foundation

/// The four review grades. Raw values match FSRS (1 Again · 2 Hard · 3 Good · 4 Easy).
public enum ReviewRating: Int, CaseIterable, Sendable {
    case forgot = 1   // 忘了 (Again)
    case fuzzy = 2    // 模糊 (Hard)
    case good = 3     // 记得 (Good)
    case easy = 4     // 简单 (Easy)

    public var label: String {
        switch self { case .forgot: "忘了"; case .fuzzy: "模糊"; case .good: "记得"; case .easy: "简单" }
    }
}

public enum CardState: Int, Sendable { case new = 0, learning = 1, review = 2, relearning = 3 }

/// FSRS memory state of one card.
public struct ReviewState: Equatable, Sendable {
    public var state: CardState
    /// Index into the (re)learning steps while learning/relearning.
    public var step: Int?
    public var stability: Double?
    public var difficulty: Double?
    /// The interval that was scheduled at the last review, in days (fractions for learning steps).
    public var intervalDays: Double
    public var repetitions: Int
    public var lapses: Int
    public var due: Date
    public var lastReviewed: Date?

    public init(state: CardState, step: Int? = nil, stability: Double? = nil, difficulty: Double? = nil,
                intervalDays: Double = 0, repetitions: Int = 0, lapses: Int = 0, due: Date, lastReviewed: Date? = nil) {
        self.state = state; self.step = step; self.stability = stability; self.difficulty = difficulty
        self.intervalDays = intervalDays; self.repetitions = repetitions; self.lapses = lapses
        self.due = due; self.lastReviewed = lastReviewed
    }

    public static func new(now: Date) -> ReviewState { ReviewState(state: .new, due: now) }
}

/// FSRS-6 scheduler: a clean-room Swift implementation of the published formulas
/// (open-spaced-repetition), with default parameters, learning/relearning steps and no fuzz.
public struct FSRS: Sendable, Equatable {
    public static let defaultParameters: [Double] = [
        0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722, 0.1666, 0.796,
        1.4835, 0.0614, 0.2629, 1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542,
    ]
    public static let minStability = 0.001

    public var w: [Double]
    public var desiredRetention: Double
    public var learningSteps: [TimeInterval]
    public var relearningSteps: [TimeInterval]
    public var maximumInterval: Int

    public init(parameters: [Double] = FSRS.defaultParameters, desiredRetention: Double = 0.9,
                learningSteps: [TimeInterval] = [60, 600], relearningSteps: [TimeInterval] = [600],
                maximumInterval: Int = 36_500) {
        precondition(parameters.count == 21, "FSRS-6 takes 21 parameters")
        w = parameters; self.desiredRetention = desiredRetention
        self.learningSteps = learningSteps; self.relearningSteps = relearningSteps
        self.maximumInterval = maximumInterval
    }

    /// "1m 10m" → [60, 600]. Units s/m/h/d; a bare number means minutes. Nil if anything is unreadable.
    public static func parseSteps(_ text: String) -> [TimeInterval]? {
        var out: [TimeInterval] = []
        for tok in text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "，" }) {
            var t = tok.lowercased(); var mul: Double = 60
            if let u = t.last, "smhd".contains(u) { mul = ["s": 1, "m": 60, "h": 3600, "d": 86_400][String(u)]!; t.removeLast() }
            guard let v = Double(t), v > 0 else { return nil }
            out.append(v * mul)
        }
        return out
    }
    public static func formatSteps(_ steps: [TimeInterval]) -> String {
        steps.map { s in
            if s >= 86_400, s.truncatingRemainder(dividingBy: 86_400) == 0 { return "\(Int(s / 86_400))d" }
            if s >= 3600, s.truncatingRemainder(dividingBy: 3600) == 0 { return "\(Int(s / 3600))h" }
            if s >= 60, s.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(s / 60))m" }
            return "\(Int(s))s"
        }.joined(separator: " ")
    }

    var decay: Double { -w[20] }
    var factor: Double { pow(0.9, 1 / decay) - 1 }

    public func retrievability(elapsedDays t: Double, stability s: Double) -> Double {
        pow(1 + factor * t / s, decay)
    }

    public func initialStability(_ g: ReviewRating) -> Double { max(w[g.rawValue - 1], Self.minStability) }

    func initialDifficultyRaw(_ g: ReviewRating) -> Double { w[4] - exp(w[5] * Double(g.rawValue - 1)) + 1 }
    public func initialDifficulty(_ g: ReviewRating) -> Double { clampD(initialDifficultyRaw(g)) }
    func clampD(_ d: Double) -> Double { min(max(d, 1), 10) }

    public func nextDifficulty(_ d: Double, _ g: ReviewRating) -> Double {
        let delta = -w[6] * Double(g.rawValue - 3)
        let damped = d + (10 - d) * delta / 9
        return clampD(w[7] * initialDifficultyRaw(.easy) + (1 - w[7]) * damped)
    }

    public func shortTermStability(_ s: Double, _ g: ReviewRating) -> Double {
        var inc = exp(w[17] * (Double(g.rawValue) - 3 + w[18])) * pow(s, -w[19])
        if g != .forgot { inc = max(inc, 1) }
        return max(s * inc, Self.minStability)
    }

    public func nextStability(d: Double, s: Double, r: Double, _ g: ReviewRating) -> Double {
        let out: Double
        if g == .forgot {
            let long = w[11] * pow(d, -w[12]) * (pow(s + 1, w[13]) - 1) * exp((1 - r) * w[14])
            let short = s / exp(w[17] * w[18])
            out = min(long, short)
        } else {
            let hard = g == .fuzzy ? w[15] : 1, easy = g == .easy ? w[16] : 1
            out = s * (1 + exp(w[8]) * (11 - d) * pow(s, -w[9]) * (exp((1 - r) * w[10]) - 1) * hard * easy)
        }
        return max(out, Self.minStability)
    }

    /// Whole days until retrievability falls to the desired retention (at least 1).
    public func nextIntervalDays(_ s: Double) -> Int {
        let i = (s / factor) * (pow(desiredRetention, 1 / decay) - 1)
        return min(max(Int(i.rounded()), 1), maximumInterval)
    }

    public func next(_ c: ReviewState, rating g: ReviewRating, now: Date) -> ReviewState {
        var n = c
        let elapsed: Double? = c.lastReviewed.map { floor(now.timeIntervalSince($0) / 86_400) }
        var interval: TimeInterval     // seconds

        func updateMemory() {
            if let s = n.stability, let d = n.difficulty {
                if let e = elapsed, e < 1 {
                    n.stability = shortTermStability(s, g)
                } else {
                    n.stability = nextStability(d: d, s: s, r: retrievability(elapsedDays: elapsed ?? 0, stability: s), g)
                }
                n.difficulty = nextDifficulty(d, g)
            } else {
                n.stability = initialStability(g); n.difficulty = initialDifficulty(g)
            }
        }
        func toReview() -> TimeInterval {
            n.state = .review; n.step = nil
            return Double(nextIntervalDays(n.stability!)) * 86_400
        }
        func stepped(_ steps: [TimeInterval]) -> TimeInterval {
            let step = n.step ?? 0
            if steps.isEmpty || (step >= steps.count && g != .forgot) { return toReview() }
            switch g {
            case .forgot: n.step = 0; return steps[0]
            case .fuzzy:
                if step == 0 { return steps.count == 1 ? steps[0] * 1.5 : (steps[0] + steps[1]) / 2 }
                return steps[step]
            case .good:
                if step + 1 == steps.count { return toReview() }
                n.step = step + 1; return steps[step + 1]
            case .easy: return toReview()
            }
        }

        switch c.state {
        case .new, .learning:
            if c.state == .new { n.state = .learning; n.step = 0 }
            updateMemory()
            interval = stepped(learningSteps)
        case .review:
            updateMemory()
            if g == .forgot {
                n.lapses += 1
                if relearningSteps.isEmpty { interval = toReview() }
                else { n.state = .relearning; n.step = 0; interval = relearningSteps[0] }
            } else {
                interval = Double(nextIntervalDays(n.stability!)) * 86_400
            }
        case .relearning:
            updateMemory()
            interval = stepped(relearningSteps)
        }
        n.repetitions += 1
        n.lastReviewed = now
        n.intervalDays = interval / 86_400
        n.due = now.addingTimeInterval(interval)
        return n
    }
}

public enum Scheduler {
    /// The scheduler used by the wordbook; the app updates it from Settings › 背单词.
    nonisolated(unsafe) public static var shared = FSRS()

    public static func next(_ s: ReviewState, rating: ReviewRating, now: Date) -> ReviewState {
        shared.next(s, rating: rating, now: now)
    }

    /// 斩 / 已掌握: a retired card is scheduled a century out and never planned again.
    public static let masteredInterval: Double = 36_500
    public static func isMastered(_ s: ReviewState) -> Bool { s.intervalDays >= masteredInterval }
    public static func retire(_ s: ReviewState, now: Date) -> ReviewState {
        var n = s
        n.lastReviewed = now; n.repetitions += 1
        n.state = .review; n.step = nil
        n.stability = max(s.stability ?? 0, masteredInterval)
        n.difficulty = s.difficulty ?? 1
        n.intervalDays = masteredInterval
        n.due = now.addingTimeInterval(masteredInterval * 86_400)
        return n
    }

    /// Approximate FSRS state for a card scheduled by the old SM-2 scheduler.
    /// Stability ≈ the current interval; difficulty from ease (2.5 → 5, 1.3 → 9, ≥ 3.1 → 3).
    public static func migrate(ease: Double, intervalDays: Double, repetitions: Int, lapses: Int,
                               due: Date, lastReviewed: Date?) -> ReviewState {
        if repetitions == 0 && lastReviewed == nil && lapses == 0 {
            return ReviewState(state: .new, due: due)
        }
        let d = min(max(5 + (2.5 - ease) * (4 / 1.2), 1), 10)
        if intervalDays >= 1 {
            return ReviewState(state: .review, stability: intervalDays, difficulty: d, intervalDays: intervalDays,
                               repetitions: repetitions, lapses: lapses, due: due, lastReviewed: lastReviewed)
        }
        // Forgotten under SM-2 (interval reset): relearning with a small stability.
        return ReviewState(state: lapses > 0 ? .relearning : .learning, step: 0, stability: shared.initialStability(.forgot),
                           difficulty: d, intervalDays: intervalDays, repetitions: repetitions, lapses: lapses,
                           due: due, lastReviewed: lastReviewed)
    }
}
