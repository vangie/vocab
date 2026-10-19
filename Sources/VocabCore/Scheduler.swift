import Foundation

/// The three buttons shown during review.
public enum ReviewRating: Int, CaseIterable, Sendable {
    case forgot = 1   // 忘了
    case fuzzy = 2    // 模糊
    case good = 3     // 记得

    public var label: String {
        switch self { case .forgot: "忘了"; case .fuzzy: "模糊"; case .good: "记得" }
    }
}

/// Spaced-repetition state of one card.
public struct ReviewState: Equatable, Sendable {
    public var ease: Double
    public var intervalDays: Double
    public var repetitions: Int
    public var lapses: Int
    public var due: Date
    public var lastReviewed: Date?

    public static func new(now: Date) -> ReviewState {
        ReviewState(ease: 2.5, intervalDays: 0, repetitions: 0, lapses: 0, due: now, lastReviewed: nil)
    }
}

/// A simplified SM-2 with three grades.
/// - 忘了: relearn in 10 minutes, repetitions reset, ease −0.20.
/// - 模糊: 1 d → 3 d → interval × 1.2, ease −0.15.
/// - 记得: 1 d → 6 d → interval × ease.
public enum Scheduler {
    public static let minEase = 1.3
    public static let relearnDelay: TimeInterval = 10 * 60

    public static func next(_ s: ReviewState, rating: ReviewRating, now: Date) -> ReviewState {
        var n = s
        n.lastReviewed = now
        switch rating {
        case .forgot:
            n.repetitions = 0
            n.lapses += 1
            n.ease = max(minEase, s.ease - 0.20)
            n.intervalDays = 0
            n.due = now.addingTimeInterval(relearnDelay)
            return n
        case .fuzzy:
            n.ease = max(minEase, s.ease - 0.15)
            switch s.repetitions {
            case 0: n.intervalDays = 1
            case 1: n.intervalDays = 3
            default: n.intervalDays = max(s.intervalDays + 1, (s.intervalDays * 1.2).rounded())
            }
        case .good:
            switch s.repetitions {
            case 0: n.intervalDays = 1
            case 1: n.intervalDays = 6
            default: n.intervalDays = max(s.intervalDays + 1, (s.intervalDays * s.ease).rounded())
            }
        }
        n.repetitions += 1
        n.due = now.addingTimeInterval(n.intervalDays * 86_400)
        return n
    }
}
