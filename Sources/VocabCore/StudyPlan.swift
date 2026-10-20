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
    public var dailyReview = 20
    /// The user changed the review limit (so a stored 200 is theirs, not the old default).
    public var reviewEdited = false
    public var targetDate: Date? = nil
    /// Wordbook words are drawn before word-list words.
    public var wordbookFirst = true
    /// Set once the user has seen the plan sheet.
    public var configured = false
    public init() {}

    enum CodingKeys: String, CodingKey { case sources, dailyNew, dailyReview, reviewEdited, targetDate, wordbookFirst, configured }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        sources = try c.decodeIfPresent([PlanSource].self, forKey: .sources) ?? []
        dailyNew = try c.decodeIfPresent(Int.self, forKey: .dailyNew) ?? 20
        dailyReview = try c.decodeIfPresent(Int.self, forKey: .dailyReview) ?? 20
        reviewEdited = try c.decodeIfPresent(Bool.self, forKey: .reviewEdited) ?? false
        targetDate = try c.decodeIfPresent(Date.self, forKey: .targetDate)
        wordbookFirst = try c.decodeIfPresent(Bool.self, forKey: .wordbookFirst) ?? true
        configured = try c.decodeIfPresent(Bool.self, forKey: .configured) ?? false
        // Old default review limit (200) that was never touched → the new default.
        if dailyReview == 200 && !reviewEdited { dailyReview = 20 }
    }

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

/// Shares of the chosen sources as percentages in 5% steps that add up to 100.
public enum PlanRatios {
    public static let step = 5.0

    public static func equal(_ n: Int) -> [Double] {
        guard n > 0 else { return [] }
        let units = Int(100 / step), base = units / n, extra = units % n
        return (0..<n).map { Double(base + ($0 < extra ? 1 : 0)) * step }
    }

    /// Scale to 100, round to 5% (each at least 5%), fix rounding on the largest share.
    public static func snap(_ r: [Double]) -> [Double] {
        guard !r.isEmpty else { return [] }
        let total = r.reduce(0, +)
        guard total > 0, r.count <= Int(100 / step) else { return equal(r.count) }
        var out = r.map { max(step, ($0 / total * 100 / step).rounded() * step) }
        var diff = 100 - out.reduce(0, +)
        while diff != 0 {
            let i: Int
            if diff > 0 { i = out.indices.min { out[$0] < out[$1] }! }
            else { guard let j = out.indices.filter({ out[$0] > step }).max(by: { out[$0] < out[$1] }) else { break }; i = j }
            out[i] += diff > 0 ? step : -step; diff += diff > 0 ? -step : step
        }
        return out
    }

    /// Drag the divider after segment `i` to `position` (0–100, cumulative). Only `i` and `i+1` change.
    public static func moveDivider(_ r: [Double], after i: Int, to position: Double) -> [Double] {
        guard i >= 0, i + 1 < r.count else { return r }
        let start = r[..<i].reduce(0, +), end = start + r[i] + r[i + 1]
        let x = min(max((position / step).rounded() * step, start + step), end - step)
        var out = r
        out[i] = x - start; out[i + 1] = end - x
        return out
    }

    /// Give `i` 5% more (or less) from a neighbour (VoiceOver increment/decrement).
    public static func nudge(_ r: [Double], _ i: Int, by delta: Double) -> [Double] {
        guard r.count > 1, r.indices.contains(i) else { return r }
        let j = i + 1 < r.count ? i + 1 : i - 1
        var out = r
        let d = delta > 0 ? min(delta, out[j] - step) : max(delta, step - out[i])
        out[i] += d; out[j] -= d
        return out
    }
}
