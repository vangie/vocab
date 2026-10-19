import Foundation

/// Seam for a future AI explanation provider (out of scope for v1).
public protocol WordExplainer: Sendable {
    func explain(word: String, context: String?) async throws -> String
}

/// Seam for future wordbook sync (out of scope for v1).
public protocol WordbookSync: Sendable {
    func push(_ items: [WordItem]) async throws
    func pull() async throws -> [WordItem]
}

/// Default: no AI, no sync.
public struct NoExplainer: WordExplainer {
    public init() {}
    public func explain(word: String, context: String?) async throws -> String { "" }
}
