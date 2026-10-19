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
