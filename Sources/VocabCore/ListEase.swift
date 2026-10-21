import Foundation

/// How easy a word list is for this user: per list, a rolling window of first-sight outcomes of new
/// words (true = 斩'd at first sight). Drives the 「换一本更难的词书」 suggestion. Stored in UserDefaults.
public struct ListEase: Codable, Equatable, Sendable {
    public static let window = 100
    public static let minSamples = 50
    public static let threshold = 0.7

    public var outcomes: [String: [Bool]] = [:]
    /// Lists for which the user chose 「继续当前词库」.
    public var dismissed: Set<String> = []
    public init() {}

    public mutating func record(_ list: ExamList, retiredAtFirstSight: Bool) {
        var o = outcomes[list.rawValue] ?? []
        o.append(retiredAtFirstSight)
        if o.count > Self.window { o.removeFirst(o.count - Self.window) }
        outcomes[list.rawValue] = o
    }

    public func samples(_ list: ExamList) -> Int { outcomes[list.rawValue]?.count ?? 0 }
    public func share(_ list: ExamList) -> Double {
        let o = outcomes[list.rawValue] ?? []
        return o.isEmpty ? 0 : Double(o.filter { $0 }.count) / Double(o.count)
    }
    /// ≥ 50 new words seen (last 100 kept) and ≥ 70% of them 斩'd at first sight, not dismissed.
    public func tooEasy(_ list: ExamList) -> Bool {
        !dismissed.contains(list.rawValue) && samples(list) >= Self.minSamples && share(list) >= Self.threshold
    }
    public mutating func dismiss(_ list: ExamList) { dismissed.insert(list.rawValue) }

    /// Lists from easiest to hardest, with the vocabulary size each roughly assumes.
    public static let difficulty: [(list: ExamList, level: Int)] = [
        (.zk, 1600), (.gk, 3500), (.cet4, 4500), (.ky, 5500), (.cet6, 6000), (.ielts, 7000), (.toefl, 8000), (.gre, 12000),
    ]

    /// A harder list than `current`: the first one whose level is above the test estimate (if any),
    /// else simply the next harder list. Lists in `exclude` (already active) are skipped.
    public static func recommend(after current: ExamList, estimate: Int?, exclude: Set<ExamList> = []) -> ExamList? {
        guard let i = difficulty.firstIndex(where: { $0.list == current }) else { return nil }
        let harder = difficulty[(i + 1)...].filter { !exclude.contains($0.list) }
        if let e = estimate, let hit = harder.first(where: { $0.level > e }) { return hit.list }
        if estimate != nil { return harder.last?.list }
        return harder.first?.list
    }

    public static let defaultsKey = "listEase"
    public static func load(_ d: UserDefaults = .standard) -> ListEase {
        d.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(ListEase.self, from: $0) } ?? ListEase()
    }
    public func save(_ d: UserDefaults = .standard) { d.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey) }
}
