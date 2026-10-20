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
        guard let w = Self.headword(word) else { return }
        entries.removeAll { $0.word.caseInsensitiveCompare(w) == .orderedSame }
        entries.insert(Entry(word: w, date: date), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }
    public mutating func remove(_ word: String) { entries.removeAll { $0.word.caseInsensitiveCompare(word) == .orderedSame } }
    public mutating func clear() { entries = [] }
    public var words: [String] { entries.map(\.word) }

    /// The bare headword of a lookup, or nil for things that aren't one.
    /// Strips a pinyin/reading suffix ("你们  nǐmen", "你方 nǐfāng") and rejects display labels
    /// like "Food, dish-topic food".
    public static func headword(_ raw: String) -> String? {
        var w = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = w.range(of: "  ") { w = String(w[..<r.lowerBound]) }
        let isCJK: (Character) -> Bool = { $0.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) } }
        if w.contains(where: isCJK), let sp = w.firstIndex(of: " ") {
            let rest = w[w.index(after: sp)...]
            if !rest.contains(where: isCJK) { w = String(w[..<sp]) }   // CJK word + romanization
        }
        w = w.trimmingCharacters(in: .whitespacesAndNewlines)
        if w.isEmpty || w.count > 60 || w.contains(",") || w.contains("，") || w.contains("\n") { return nil }
        return w
    }

    /// Re-normalize stored entries (drops junk from older builds), keeping order and the newest time.
    public mutating func sanitize() {
        var out: [Entry] = []
        for e in entries {
            guard let w = Self.headword(e.word),
                  !out.contains(where: { $0.word.caseInsensitiveCompare(w) == .orderedSame }) else { continue }
            out.append(Entry(word: w, date: e.date))
        }
        entries = Array(out.prefix(limit))
    }

    public static let defaultsKey = "lookupHistory"
    public static let legacyKey = "recentLookups"
    public static func load(_ d: UserDefaults = .standard, now: Date = Date()) -> LookupHistory {
        var h: LookupHistory
        if let data = d.data(forKey: defaultsKey), let x = try? JSONDecoder().decode(LookupHistory.self, from: data) { h = x }
        else {
            // Old plain list (no times): keep its order, spaced a second apart.
            let old = d.stringArray(forKey: legacyKey) ?? []
            h = LookupHistory(entries: old.enumerated().map { Entry(word: $1, date: now.addingTimeInterval(-Double($0))) })
        }
        let before = h
        h.sanitize()
        if h != before || d.data(forKey: defaultsKey) == nil { h.save(d) }
        return h
    }
    public func save(_ d: UserDefaults = .standard) { d.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey) }
}
