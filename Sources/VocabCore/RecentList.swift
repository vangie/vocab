import Foundation

/// Recent lookups with a frozen display order: `record` updates the stored history
/// immediately, but `displayed` only changes on `refresh()` (new search, relaunch),
/// so clicking a row in the sidebar never reorders what is on screen.
public struct RecentList: Equatable, Sendable {
    public private(set) var stored: [String]
    public private(set) var displayed: [String]
    public let limit: Int

    public init(_ initial: [String] = [], limit: Int = 50) {
        stored = initial; displayed = initial; self.limit = limit
    }

    public mutating func record(_ w: String) {
        guard !w.isEmpty else { return }
        stored.removeAll { $0.caseInsensitiveCompare(w) == .orderedSame }
        stored.insert(w, at: 0)
        if stored.count > limit { stored.removeLast(stored.count - limit) }
    }

    public mutating func refresh() { displayed = stored }
    public mutating func clear() { stored = []; displayed = [] }
}

/// What the 词典 sidebar shows. Recent lookups only with an empty query; any non-empty query
/// shows exactly its own suggestions (possibly none) — never another query's list.
public enum SidebarContent: Equatable, Sendable {
    case recents([String])
    case suggestions(query: String, words: [String])
    case noSuggestions(query: String)

    public static func make(query: String, suggestionsFor: String?, words: [String], recents: [String]) -> SidebarContent {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return .recents(recents) }
        // Suggestions computed for a different (older) query are stale: don't show them.
        guard suggestionsFor == q, !words.isEmpty else { return .noSuggestions(query: q) }
        return .suggestions(query: q, words: words)
    }
}
