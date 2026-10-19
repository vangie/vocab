import Foundation
import SQLite3

public struct WordItem: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var word: String
    public var definition: String
    public var dictionary: String
    public var context: String?
    public var added: Date
    public var review: ReviewState
}

public enum WordStoreError: Error { case open(String), sql(String) }

/// SQLite-backed wordbook (生词本).
public final class WordStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let url: URL?

    public static func defaultURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vocab", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vocab.sqlite")
    }

    /// Pass nil for an in-memory store (tests).
    public init(url: URL?) throws {
        self.url = url
        let path = url?.path ?? ":memory:"
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw WordStoreError.open(path) }
        try exec("""
        CREATE TABLE IF NOT EXISTS words(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          word TEXT NOT NULL UNIQUE COLLATE NOCASE,
          definition TEXT NOT NULL DEFAULT '',
          dictionary TEXT NOT NULL DEFAULT '',
          context TEXT,
          added REAL NOT NULL,
          ease REAL NOT NULL DEFAULT 2.5,
          interval REAL NOT NULL DEFAULT 0,
          reps INTEGER NOT NULL DEFAULT 0,
          lapses INTEGER NOT NULL DEFAULT 0,
          due REAL NOT NULL,
          last_reviewed REAL
        );
        CREATE INDEX IF NOT EXISTS words_due ON words(due);
        """)
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw WordStoreError.sql(m)
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func run(_ sql: String, _ binds: [Any?], row: ((OpaquePointer) -> Void)? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            throw WordStoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(st) }
        for (i, v) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case nil: sqlite3_bind_null(st, idx)
            case let s as String: sqlite3_bind_text(st, idx, s, -1, Self.transient)
            case let d as Double: sqlite3_bind_double(st, idx, d)
            case let n as Int: sqlite3_bind_int64(st, idx, Int64(n))
            case let n as Int64: sqlite3_bind_int64(st, idx, n)
            case let d as Date: sqlite3_bind_double(st, idx, d.timeIntervalSince1970)
            default: sqlite3_bind_null(st, idx)
            }
        }
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW { row?(st!) ; continue }
            if rc == SQLITE_DONE { break }
            throw WordStoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static let columns = "id, word, definition, dictionary, context, added, ease, interval, reps, lapses, due, last_reviewed"

    private static func item(_ st: OpaquePointer) -> WordItem {
        func text(_ i: Int32) -> String? { sqlite3_column_text(st, i).map { String(cString: $0) } }
        func date(_ i: Int32) -> Date? {
            sqlite3_column_type(st, i) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(st, i))
        }
        return WordItem(
            id: sqlite3_column_int64(st, 0), word: text(1) ?? "", definition: text(2) ?? "",
            dictionary: text(3) ?? "", context: text(4), added: date(5) ?? Date(),
            review: ReviewState(ease: sqlite3_column_double(st, 6), intervalDays: sqlite3_column_double(st, 7),
                                repetitions: Int(sqlite3_column_int64(st, 8)), lapses: Int(sqlite3_column_int64(st, 9)),
                                due: date(10) ?? Date(), lastReviewed: date(11)))
    }

    /// Add a word, or update its definition/context if it is already in the book.
    @discardableResult
    public func add(word: String, definition: String, dictionary: String, context: String? = nil, now: Date = Date()) throws -> WordItem {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        try run("""
        INSERT INTO words(word, definition, dictionary, context, added, due) VALUES(?,?,?,?,?,?)
        ON CONFLICT(word) DO UPDATE SET definition = excluded.definition, dictionary = excluded.dictionary,
          context = COALESCE(excluded.context, words.context)
        """, [w, definition, dictionary, context, now, now])
        return try find(word: w)!
    }

    public func find(word: String) throws -> WordItem? {
        var out: WordItem?
        try run("SELECT \(Self.columns) FROM words WHERE word = ?", [word]) { out = Self.item($0) }
        return out
    }

    public func all() throws -> [WordItem] {
        var out: [WordItem] = []
        try run("SELECT \(Self.columns) FROM words ORDER BY added DESC, id DESC", []) { out.append(Self.item($0)) }
        return out
    }

    public func due(now: Date = Date(), limit: Int = 200) throws -> [WordItem] {
        var out: [WordItem] = []
        try run("SELECT \(Self.columns) FROM words WHERE due <= ? ORDER BY due ASC LIMIT ?", [now, limit]) { out.append(Self.item($0)) }
        return out
    }

    public func update(_ item: WordItem) throws {
        try run("""
        UPDATE words SET word=?, definition=?, dictionary=?, context=?, ease=?, interval=?, reps=?, lapses=?, due=?, last_reviewed=? WHERE id=?
        """, [item.word, item.definition, item.dictionary, item.context, item.review.ease, item.review.intervalDays,
              item.review.repetitions, item.review.lapses, item.review.due, item.review.lastReviewed, item.id])
    }

    public func delete(id: Int64) throws {
        try run("DELETE FROM words WHERE id = ?", [id])
    }

    /// Apply a review rating and persist the new schedule.
    @discardableResult
    public func review(id: Int64, rating: ReviewRating, now: Date = Date()) throws -> WordItem? {
        var item: WordItem?
        try run("SELECT \(Self.columns) FROM words WHERE id = ?", [id]) { item = Self.item($0) }
        guard var it = item else { return nil }
        it.review = Scheduler.next(it.review, rating: rating, now: now)
        try update(it)
        return it
    }

    public func count() throws -> Int {
        var n = 0
        try run("SELECT COUNT(*) FROM words", []) { n = Int(sqlite3_column_int64($0, 0)) }
        return n
    }
}

/// CSV export (RFC 4180).
public enum CSVExporter {
    public static func csv(_ items: [WordItem]) -> String {
        let f = ISO8601DateFormatter()
        func q(_ s: String) -> String {
            if s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
                return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return s
        }
        var lines = ["word,definition,dictionary,context,added,due,interval_days,repetitions,lapses"]
        for i in items {
            lines.append([i.word, i.definition, i.dictionary, i.context ?? "", f.string(from: i.added),
                          f.string(from: i.review.due), String(format: "%g", i.review.intervalDays),
                          "\(i.review.repetitions)", "\(i.review.lapses)"].map(q).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
