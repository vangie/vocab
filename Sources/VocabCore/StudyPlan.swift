import Foundation

/// A word source in the 背诵计划: an exam list or one of the user's wordbooks.
public enum PlanSourceID: Hashable, Codable, Sendable {
    case list(ExamList)
    case book(Int64)
    public var isBook: Bool { if case .book = self { return true }; return false }
}

public struct PlanSource: Hashable, Codable, Sendable, Identifiable {
    public var id: PlanSourceID
    public var enabled: Bool
    /// Relative share (any positive scale; normalised over enabled sources).
    public var ratio: Double
    public init(id: PlanSourceID, enabled: Bool = true, ratio: Double = 1) { self.id = id; self.enabled = enabled; self.ratio = ratio }
}

public struct StudyPlan: Codable, Equatable, Sendable {
    public var sources: [PlanSource] = []
    public var dailyNew = 20
    public var dailyReview = 200
    public var targetDate: Date? = nil
    /// Wordbook words are drawn before word-list words.
    public var wordbookFirst = true
    /// Set once the user has seen the plan sheet.
    public var configured = false
    public init() {}

    public static let defaultsKey = "studyPlan"
    public static func load(_ d: UserDefaults = .standard) -> StudyPlan {
        d.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(StudyPlan.self, from: $0) } ?? StudyPlan()
    }
    public func save(_ d: UserDefaults = .standard) { d.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey) }
}

public enum PlanMath {
    /// New words for today: min(new limit, review limit − due), minus what was already started today.
    public static func newToday(plan: StudyPlan, due: Int, introducedToday: Int) -> Int {
        max(0, min(plan.dailyNew - introducedToday, plan.dailyReview - due))
    }

    /// Reviews shown today (due words beyond the review limit wait).
    public static func reviewsToday(plan: StudyPlan, due: Int) -> Int { min(due, max(0, plan.dailyReview)) }

    /// Days to finish `remaining` new words at the daily new limit, and the pace a target date would need.
    public static func projection(remaining: Int, plan: StudyPlan, now: Date = Date(), calendar: Calendar = .current)
        -> (days: Int, finish: Date?, neededPerDay: Int?) {
        let per = max(1, plan.dailyNew)
        let days = plan.dailyNew <= 0 ? Int.max : Int((Double(remaining) / Double(per)).rounded(.up))
        let finish = days == Int.max ? nil : calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now))
        var need: Int?
        if let t = plan.targetDate {
            let left = max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: t)).day ?? 1)
            need = Int((Double(remaining) / Double(left)).rounded(.up))
        }
        return (days, finish, need)
    }
}

/// Draws new words from several sources by ratio (smooth weighted round-robin). A word is used
/// at most once across sources and is skipped if `exclude` holds it (already learned, 斩, or in the
/// test's known bands). When a source runs dry its share flows to the others.
public enum PlanMixer {
    public struct Queue: Sendable {
        public var id: PlanSourceID
        public var ratio: Double
        public var words: [String]
        public init(id: PlanSourceID, ratio: Double, words: [String]) { self.id = id; self.ratio = ratio; self.words = words }
    }

    public static func mix(_ queues: [Queue], count: Int, exclude: Set<String> = [], wordbookFirst: Bool = true)
        -> [(word: String, source: PlanSourceID)] {
        guard count > 0 else { return [] }
        var used = Set(exclude.map { $0.lowercased() })
        var out: [(String, PlanSourceID)] = []
        let tiers: [[Queue]] = wordbookFirst
            ? [queues.filter { $0.id.isBook }, queues.filter { !$0.id.isBook }]
            : [queues]
        for tier in tiers {
            let qs = tier.filter { $0.ratio > 0 }
            var pos = Array(repeating: 0, count: qs.count)
            var credit = Array(repeating: 0.0, count: qs.count)
            func next(_ i: Int) -> String? {
                while pos[i] < qs[i].words.count {
                    let w = qs[i].words[pos[i]]; pos[i] += 1
                    if used.insert(w.lowercased()).inserted { return w }
                }
                return nil
            }
            var alive = Set(qs.indices)
            while out.count < count, !alive.isEmpty {
                let total = alive.reduce(0.0) { $0 + qs[$1].ratio }
                for i in alive { credit[i] += qs[i].ratio }
                let pick = alive.max { credit[$0] != credit[$1] ? credit[$0] < credit[$1] : $0 > $1 }!
                credit[pick] -= total
                if let w = next(pick) { out.append((w, qs[pick].id)) } else { alive.remove(pick); credit[pick] = 0 }
            }
            if out.count >= count { break }
        }
        return out
    }
}
