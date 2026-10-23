import Foundation

/// Browser-style back/forward history. Visiting truncates the forward stack; a visit equal to the
/// current entry is ignored.
public struct NavStack<T: Equatable> {
    public private(set) var items: [T] = []
    public private(set) var index = -1
    public var limit = 200
    public init() {}
    public var current: T? { items.indices.contains(index) ? items[index] : nil }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index >= 0 && index < items.count - 1 }

    public mutating func visit(_ t: T) {
        if current == t { return }
        if index < items.count - 1 { items.removeSubrange((index + 1)...) }
        items.append(t); index = items.count - 1
        if items.count > limit { items.removeFirst(items.count - limit); index = items.count - 1 }
    }
    /// Replace the current entry (e.g. the 记词 filter text changed while staying on the list).
    public mutating func replaceCurrent(_ t: T) { if items.indices.contains(index) { items[index] = t } else { visit(t) } }
    public mutating func back() -> T? { guard canGoBack else { return nil }; index -= 1; return items[index] }
    public mutating func forward() -> T? { guard canGoForward else { return nil }; index += 1; return items[index] }
}
