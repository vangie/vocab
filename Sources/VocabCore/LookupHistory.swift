import Foundation

/// Persistent 词典 lookup history: one entry per word (case-insensitive), most recent first, capped.
/// Stored as JSON in UserDefaults (no wordbook schema change); migrates the old `recentLookups` list.
public struct LookupHistory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var word: String
        public var date: Date
        public var id: String { word.lowercased() }
        public init(word: String, date: Date) { self.word = word; self.date = date }
    }
    public private(set) var entries: [Entry] = []
    public var limit = 500
    public init(entries: [Entry] = [], limit: Int = 500) { self.entries = entries; self.limit = limit }

    public mutating func record(_ word: String, at date: Date = Date()) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }
        entries.removeAll { $0.word.caseInsensitiveCompare(w) == .orderedSame }
        entries.insert(Entry(word: w, date: date), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }
    public mutating func remove(_ word: String) { entries.removeAll { $0.word.caseInsensitiveCompare(word) == .orderedSame } }
    public mutating func clear() { entries = [] }
    public var words: [String] { entries.map(\.word) }

    public static let defaultsKey = "lookupHistory"
    public static let legacyKey = "recentLookups"
    public static func load(_ d: UserDefaults = .standard, now: Date = Date()) -> LookupHistory {
        if let data = d.data(forKey: defaultsKey), let h = try? JSONDecoder().decode(LookupHistory.self, from: data) { return h }
        // Old plain list (no times): keep its order, spaced a second apart.
        let old = d.stringArray(forKey: legacyKey) ?? []
        return LookupHistory(entries: old.enumerated().map { Entry(word: $1, date: now.addingTimeInterval(-Double($0))) })
    }
    public func save(_ d: UserDefaults = .standard) { d.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey) }
}
