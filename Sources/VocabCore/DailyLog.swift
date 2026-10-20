import Foundation

/// One day of the 背诵计划: what was due when the day began and what got done.
public struct DayRecord: Codable, Equatable, Sendable {
    public var newQuota = 0, newDone = 0
    public var reviewTarget = 0, reviewsDone = 0
    public var completed = false
    /// Active study time in quiz sessions (seconds; idle gaps over 60 s not counted).
    public var studySeconds: Double = 0
    /// Nothing was scheduled that day: it neither counts nor breaks the streak.
    public var isRest: Bool { newQuota + reviewTarget == 0 }
    public init() {}

    enum CodingKeys: String, CodingKey { case newQuota, newDone, reviewTarget, reviewsDone, completed, studySeconds }
    public init(from d: Decoder) throws {   // tolerate records saved before studySeconds existed
        let c = try d.container(keyedBy: CodingKeys.self)
        newQuota = try c.decodeIfPresent(Int.self, forKey: .newQuota) ?? 0
        newDone = try c.decodeIfPresent(Int.self, forKey: .newDone) ?? 0
        reviewTarget = try c.decodeIfPresent(Int.self, forKey: .reviewTarget) ?? 0
        reviewsDone = try c.decodeIfPresent(Int.self, forKey: .reviewsDone) ?? 0
        completed = try c.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        studySeconds = try c.decodeIfPresent(Double.self, forKey: .studySeconds) ?? 0
    }
}

/// Per-day progress, kept in UserDefaults (no wordbook schema change). Streak = consecutive days
/// on which today's new quota and the due reviews were all finished. Today still in progress
/// doesn't break it; a day with nothing scheduled is skipped; a missed day ends it.
public struct DailyLog: Codable, Equatable, Sendable {
    public var days: [String: DayRecord] = [:]
    public init() {}

    public static func key(_ d: Date, _ cal: Calendar = .current) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Record the current state: `newLeft` / `reviewsLeft` still waiting today, `newDone` / `reviewsDone` so far.
    /// The day's targets are fixed by the first snapshot (later additions raise them, never lower them).
    public mutating func snapshot(_ now: Date, newLeft: Int, reviewsLeft: Int, newDone: Int, reviewsDone: Int, calendar: Calendar = .current) {
        let k = Self.key(now, calendar)
        var r = days[k] ?? DayRecord()
        r.newDone = max(r.newDone, newDone); r.reviewsDone = max(r.reviewsDone, reviewsDone)
        r.newQuota = max(r.newQuota, r.newDone + newLeft)
        // Reviews: done + what is still queueable now (not a high-water mark), so a card that leaves the
        // queue (斩, or filtered as a known-common word) also leaves the denominator: 13/14 can't stick.
        r.reviewTarget = r.reviewsDone + reviewsLeft
        if newLeft == 0 && reviewsLeft == 0 && !r.isRest { r.completed = true }
        days[k] = r
        prune(now, calendar)
    }

    /// Adds active study time between two interactions; a gap longer than `idleCap` is idle and not counted.
    public mutating func addStudy(_ seconds: Double, at now: Date, idleCap: Double = 60, calendar: Calendar = .current) {
        guard seconds > 0, seconds <= idleCap else { return }   // longer gap = idle, not counted
        let k = Self.key(now, calendar)
        var r = days[k] ?? DayRecord()
        r.studySeconds += seconds
        days[k] = r
    }

    public func today(_ now: Date, calendar: Calendar = .current) -> DayRecord { days[Self.key(now, calendar)] ?? DayRecord() }

    public func streak(_ now: Date, calendar: Calendar = .current) -> Int {
        var n = today(now, calendar: calendar).completed ? 1 : 0
        var d = calendar.startOfDay(for: now)
        for _ in 0..<800 {
            d = calendar.date(byAdding: .day, value: -1, to: d)!
            guard let r = days[Self.key(d, calendar)] else { break }
            if r.completed { n += 1 } else if r.isRest { continue } else { break }
        }
        return n
    }

    mutating func prune(_ now: Date, _ cal: Calendar) {
        guard days.count > 800, let cut = cal.date(byAdding: .day, value: -800, to: now) else { return }
        let ck = Self.key(cut, cal)
        days = days.filter { $0.key >= ck }
    }

    public static let defaultsKey = "dailyLog"
    public static func load(_ d: UserDefaults = .standard) -> DailyLog {
        d.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(DailyLog.self, from: $0) } ?? DailyLog()
    }
    public func save(_ d: UserDefaults = .standard) { d.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey) }
}

/// Overall progress over the plan's sources.
public struct PlanProgress: Equatable, Sendable {
    public var total = 0, learned = 0, mastered = 0
    public init(total: Int = 0, learned: Int = 0, mastered: Int = 0) { self.total = total; self.learned = learned; self.mastered = mastered }
    public var fraction: Double { total > 0 ? Double(learned) / Double(total) : 0 }

    /// `words`: every word in the selected sources (lowercased); `skipped`: words left out (test / top-1000);
    /// `items`: the wordbook. Learned = answered at least once or 斩; mastered = 熟悉 (stability ≥ 21) or 已斩.
    public static func compute(words: Set<String>, skipped: Set<String>, items: [WordItem]) -> PlanProgress {
        let pool = words.subtracting(skipped)
        var learned = Set<String>(), mastered = Set<String>()
        for i in items {
            let w = i.word.lowercased()
            guard pool.contains(w), i.review.state != .new || Scheduler.isMastered(i.review) else { continue }
            learned.insert(w)
            if Scheduler.isMastered(i.review) || (i.review.stability ?? 0) >= 21 { mastered.insert(w) }
        }
        return PlanProgress(total: pool.count, learned: learned.count, mastered: mastered.count)
    }
}
