import Foundation
import SQLite3

/// Schema 3: vocabulary-test history and bulk-斩 batches (undoable) for the study plan.
public struct RetireBatch: Equatable, Sendable {
    public var id: Int64
    public var created: Date
    public var label: String
    public var count: Int
    public var undone: Bool
}

extension WordStore {
    static let v3SQL = """
    CREATE TABLE IF NOT EXISTS test_results(id INTEGER PRIMARY KEY AUTOINCREMENT, taken REAL NOT NULL, estimate INTEGER NOT NULL, json TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS batches(id INTEGER PRIMARY KEY AUTOINCREMENT, created REAL NOT NULL, label TEXT NOT NULL, undone INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS pool_skips(word TEXT PRIMARY KEY COLLATE NOCASE, batch_id INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS batch_items(batch_id INTEGER NOT NULL, word_id INTEGER NOT NULL, interval REAL, reps INTEGER, due REAL,
      last_reviewed REAL, stability REAL, difficulty REAL, state INTEGER, step INTEGER, PRIMARY KEY(batch_id, word_id));
    """

    public func saveTestResult(_ r: VocabTestResult) throws {
        let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        try runPublic("INSERT INTO test_results(taken, estimate, json) VALUES(?,?,?)", [r.date, r.estimate, json])
    }

    /// Newest first.
    /// 识字量测试 results (newest first); separate from 词汇量 so they never drive the word plan.
    /// Additive table (no data touched), created on first use rather than by a version migration.
    static let hanziSQL = "CREATE TABLE IF NOT EXISTS hanzi_results(id INTEGER PRIMARY KEY AUTOINCREMENT, taken REAL NOT NULL, estimate INTEGER NOT NULL, json TEXT NOT NULL)"

    public func saveHanziResult(_ r: VocabTestResult) throws {
        try runPublic(Self.hanziSQL, [])
        let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        try runPublic("INSERT INTO hanzi_results(taken, estimate, json) VALUES(?,?,?)", [r.date, r.estimate, json])
    }

    public func hanziResults() throws -> [VocabTestResult] {
        try runPublic(Self.hanziSQL, [])
        var out: [VocabTestResult] = []
        try runPublic("SELECT json FROM hanzi_results ORDER BY taken DESC, id DESC", []) { st in
            if let t = sqlite3_column_text(st, 0), let r = try? JSONDecoder().decode(VocabTestResult.self, from: Data(String(cString: t).utf8)) {
                out.append(r)
            }
        }
        return out
    }

    public func testResults() throws -> [VocabTestResult] {
        var out: [VocabTestResult] = []
        try runPublic("SELECT json FROM test_results ORDER BY taken DESC, id DESC", []) { st in
            if let t = sqlite3_column_text(st, 0), let r = try? JSONDecoder().decode(VocabTestResult.self, from: Data(String(cString: t).utf8)) {
                out.append(r)
            }
        }
        return out
    }

    /// 斩 many words at once as one undoable batch: wordbook words are retired (old state kept),
    /// others go into the plan's skip pool so word lists never serve them.
    @discardableResult
    public func bulkRetire(_ words: [String], label: String, now: Date = Date()) throws -> RetireBatch {
        try transaction {
            try runPublic("INSERT INTO batches(created, label) VALUES(?, ?)", [now, label])
            let bid = lastRowID
            for w in Set(words.map { $0.lowercased() }) {
                if let it = try find(word: w) {
                    if Scheduler.isMastered(it.review) { continue }
                    let r = it.review
                    try runPublic("INSERT OR IGNORE INTO batch_items VALUES(?,?,?,?,?,?,?,?,?,?)",
                                  [bid, it.id, r.intervalDays, r.repetitions, r.due, r.lastReviewed, r.stability, r.difficulty, r.state.rawValue, r.step])
                    _ = try retire(id: it.id, now: now)
                } else {
                    try runPublic("INSERT OR IGNORE INTO pool_skips(word, batch_id) VALUES(?, ?)", [w, bid])
                }
            }
            return try batch(bid)!
        }
    }

    public func batch(_ id: Int64) throws -> RetireBatch? {
        var out: RetireBatch?
        try runPublic("""
        SELECT id, created, label, undone,
          (SELECT COUNT(*) FROM batch_items WHERE batch_id = batches.id) + (SELECT COUNT(*) FROM pool_skips WHERE batch_id = batches.id)
        FROM batches WHERE id = ?
        """, [id]) { st in
            out = RetireBatch(id: sqlite3_column_int64(st, 0), created: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)),
                              label: String(cString: sqlite3_column_text(st, 2)), count: Int(sqlite3_column_int64(st, 4)),
                              undone: sqlite3_column_int64(st, 3) != 0)
        }
        return out
    }

    public func latestBatch() throws -> RetireBatch? {
        var id: Int64?
        try runPublic("SELECT id FROM batches WHERE undone = 0 ORDER BY id DESC LIMIT 1", []) { id = sqlite3_column_int64($0, 0) }
        return try id.flatMap { try batch($0) }
    }

    /// Undo a bulk 斩: restore each word's previous schedule and release the skipped words.
    public func undoBatch(_ id: Int64) throws {
        try transaction {
            try runPublic("""
            UPDATE words SET interval = b.interval, reps = b.reps, due = b.due, last_reviewed = b.last_reviewed,
              stability = b.stability, difficulty = b.difficulty, state = b.state, step = b.step
            FROM (SELECT * FROM batch_items WHERE batch_id = ?) AS b WHERE words.id = b.word_id
            """, [id])
            try runPublic("DELETE FROM pool_skips WHERE batch_id = ?", [id])
            try runPublic("UPDATE batches SET undone = 1 WHERE id = ?", [id])
        }
    }

    /// Words the plan must not serve as new: skipped by a test, or learned / 斩 in the wordbook.
    /// Words a vocabulary test skipped (not undone).
    public func poolSkips() throws -> Set<String> {
        var out = Set<String>()
        try runPublic("SELECT word FROM pool_skips", []) { out.insert(String(cString: sqlite3_column_text($0, 0)).lowercased()) }
        return out
    }

    public func planExclusions() throws -> Set<String> {
        var out = Set<String>()
        try runPublic("SELECT word FROM pool_skips", []) { out.insert(String(cString: sqlite3_column_text($0, 0)).lowercased()) }
        try runPublic("SELECT word FROM words WHERE state <> 0 OR interval >= ?", [Scheduler.masteredInterval]) {
            out.insert(String(cString: sqlite3_column_text($0, 0)).lowercased())
        }
        return out
    }
}

