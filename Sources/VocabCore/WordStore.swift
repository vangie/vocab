import Foundation
import SQLite3

public struct WordItem: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var word: String
    public var definition: String
    public var dictionary: String
    /// Latest context sentence (all of them are in `WordStore.contexts(for:)`).
    public var context: String?
    public var added: Date
    public var review: ReviewState
    /// Base form ("appalled" → "appal"); nil when it equals `word`.
    public var lemma: String? = nil
    /// Where the word was first met: app name, page/book title, URL.
    public var sourceApp: String? = nil
    public var sourceTitle: String? = nil
    public var sourceURL: String? = nil
    /// Markdown note.
    public var note: String = ""
    public var bookID: Int64? = nil
    public var tags: [String] = []
    public var contextCount: Int = 0

    public init(id: Int64, word: String, definition: String, dictionary: String, context: String?, added: Date, review: ReviewState) {
        self.id = id; self.word = word; self.definition = definition; self.dictionary = dictionary
        self.context = context; self.added = added; self.review = review
    }

    public var familiarity: Familiarity { Familiarity(review) }

    /// What the 来源 column shows: page/book title, else host, else app.
    public var sourceLabel: String {
        if let t = sourceTitle, !t.isEmpty { return t }
        if let u = sourceURL.flatMap(URL.init(string:)), let h = u.host { return h }
        return sourceApp ?? ""
    }
}

/// 熟悉度, derived from the FSRS memory state.
public enum Familiarity: Int, CaseIterable, Sendable, Identifiable {
    case new, learning, familiar, retired
    public var id: Int { rawValue }
    /// Stability (days) from which a reviewed card counts as 熟悉.
    public static let familiarStability: Double = 21

    public init(_ r: ReviewState) {
        if Scheduler.isMastered(r) { self = .retired }
        else if r.state == .new { self = .new }
        else if r.state == .review, (r.stability ?? 0) >= Self.familiarStability { self = .familiar }
        else { self = .learning }
    }

    public var title: String {
        switch self { case .new: "新词"; case .learning: "学习中"; case .familiar: "熟悉"; case .retired: "已斩" }
    }
}

public struct WordContext: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var wordID: Int64
    public var sentence: String
    /// The form met in this sentence ("appalled" for the word "appal").
    public var surface: String?
    public var sourceApp: String?
    public var sourceTitle: String?
    public var sourceURL: String?
    public var added: Date
}

public struct Wordbook: Identifiable, Equatable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var isDefault: Bool
}

/// Where a word was looked up.
public struct WordSource: Equatable, Sendable {
    public var app: String?
    public var title: String?
    public var url: String?
    public init(app: String? = nil, title: String? = nil, url: String? = nil) {
        self.app = app; self.title = title; self.url = url
    }
}

public enum WordStoreError: Error { case open(String), sql(String) }

/// SQLite-backed wordbook (生词本).
public final class WordStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let url: URL?
    public static let schemaVersion = 3

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
        try exec("PRAGMA foreign_keys = ON")
        let existed = try tableExists("words")
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
          last_reviewed REAL,
          stability REAL,
          difficulty REAL,
          state INTEGER NOT NULL DEFAULT 0,
          step INTEGER
        );
        CREATE INDEX IF NOT EXISTS words_due ON words(due);
        """)
        try migrateToFSRS()
        try migrateToV2(existed: existed)
        try migrateToV3()
        try migrateToV4()
    }

    /// Schema 4: words studied from a 词书 live outside every wordbook (book_id NULL) — 生词本 holds only
    /// what the user collected. Moves earlier 词书 words (source 词书·…, never looked up with a context)
    /// out of their wordbook; FSRS state, 斩 and due dates are untouched. Backed up first.
    private func migrateToV4() throws {
        var v = 0
        try run("PRAGMA user_version", []) { v = Int(sqlite3_column_int64($0, 0)) }
        guard v < 4 else { return }
        var n = 0
        try run("""
        SELECT COUNT(*) FROM words WHERE book_id IS NOT NULL AND source_app LIKE '词书·%'
          AND NOT EXISTS (SELECT 1 FROM contexts c WHERE c.word_id = words.id)
        """, []) { n = Int(sqlite3_column_int64($0, 0)) }
        var backup: URL?
        if n > 0 { backup = try backupFile(tag: "v3") }
        try transaction {
            try run("""
            UPDATE words SET book_id = NULL WHERE book_id IS NOT NULL AND source_app LIKE '词书·%'
              AND NOT EXISTS (SELECT 1 FROM contexts c WHERE c.word_id = words.id)
            """, [])
            try exec("PRAGMA user_version = 4")
        }
        if n > 0 { migrationV4 = (backup, n) }
    }

    /// Set when this open moved 词书 words out of the wordbooks (schema 4).
    public private(set) var migrationV4: (backup: URL?, moved: Int)?

    /// A word-list word studied for the first time: stored for its FSRS state but in no wordbook.
    @discardableResult
    public func addStudied(word: String, definition: String, dictionary: String, source: WordSource?, now: Date = Date()) throws -> WordItem {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        try run("""
        INSERT INTO words(word, definition, dictionary, added, due, source_app, source_title, book_id)
          VALUES(?,?,?,?,?,?,?,NULL) ON CONFLICT(word) DO NOTHING
        """, [w, definition, dictionary, now, now, Self.clean(source?.app), Self.clean(source?.title)])
        return try find(word: w)!
    }

    /// Schema 3: test history and bulk-斩 tables (new tables only; existing data untouched, still backed up).
    private func migrateToV3() throws {
        var v = 0
        try run("PRAGMA user_version", []) { v = Int(sqlite3_column_int64($0, 0)) }
        guard v < 3 else { return }
        if try count() > 0, migrationV2 == nil { migrationV3Backup = try backupFile(tag: "v2") }
        try exec(Self.v3SQL)
        try exec("PRAGMA user_version = 3")
    }

    public private(set) var migrationV3Backup: URL?

    func runPublic(_ sql: String, _ binds: [Any?], row: ((OpaquePointer) -> Void)? = nil) throws { try run(sql, binds, row: row) }
    var lastRowID: Int64 { sqlite3_last_insert_rowid(db) }

    /// Set when this open migrated an SM-2 wordbook to FSRS.
    public private(set) var migration: (backup: URL?, cards: Int)?
    /// Set when this open upgraded the wordbook to schema 2 (contexts, sources, tags, books).
    public private(set) var migrationV2: (backup: URL?, words: Int)?

    private func tableExists(_ name: String) throws -> Bool {
        var n = 0
        try run("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?", [name]) { n = Int(sqlite3_column_int64($0, 0)) }
        return n > 0
    }

    private func columnNames() throws -> Set<String> {
        var out = Set<String>()
        try run("PRAGMA table_info(words)", []) { out.insert(String(cString: sqlite3_column_text($0, 1))) }
        return out
    }

    private func backupFile(tag: String) throws -> URL? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        var b = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-backup-\(tag)-" + f.string(from: Date()) + ".sqlite")
        var i = 2
        while FileManager.default.fileExists(atPath: b.path) {
            b = b.deletingPathExtension().appendingPathExtension("\(i).sqlite"); i += 1
        }
        // VACUUM INTO gives a consistent copy even with a WAL; fall back to a file copy.
        if (try? run("VACUUM INTO ?", [b.path])) == nil { try FileManager.default.copyItem(at: url, to: b) }
        return b
    }

    /// SM-2 → FSRS: back the file up next to itself, add the FSRS columns and convert every card
    /// (stability ≈ interval, difficulty from ease).
    private func migrateToFSRS() throws {
        guard !(try columnNames()).contains("stability") else { return }
        let backup = try backupFile(tag: "sm2")
        try exec("BEGIN")
        do {
            try exec("""
            ALTER TABLE words ADD COLUMN stability REAL;
            ALTER TABLE words ADD COLUMN difficulty REAL;
            ALTER TABLE words ADD COLUMN state INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE words ADD COLUMN step INTEGER;
            """)
            var rows: [(Int64, ReviewState)] = []
            try run("SELECT id, ease, interval, reps, lapses, due, last_reviewed FROM words", []) { st in
                let last = sqlite3_column_type(st, 6) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(st, 6))
                rows.append((sqlite3_column_int64(st, 0), Scheduler.migrate(
                    ease: sqlite3_column_double(st, 1), intervalDays: sqlite3_column_double(st, 2),
                    repetitions: Int(sqlite3_column_int64(st, 3)), lapses: Int(sqlite3_column_int64(st, 4)),
                    due: Date(timeIntervalSince1970: sqlite3_column_double(st, 5)), lastReviewed: last)))
            }
            for (id, r) in rows {
                try run("UPDATE words SET stability=?, difficulty=?, state=?, step=? WHERE id=?",
                        [r.stability, r.difficulty, r.state.rawValue, r.step, id])
            }
            try exec("COMMIT")
            migration = (backup, rows.count)
        } catch { try? exec("ROLLBACK"); throw error }
    }

    /// Schema 2: lemma / source / note / wordbook columns, plus contexts, tags and books tables.
    /// Existing context sentences move into `contexts`; every word lands in the default wordbook.
    private func migrateToV2(existed: Bool) throws {
        guard !(try columnNames()).contains("book_id") else { return }
        let n = try count()
        let backup = existed && n > 0 ? try backupFile(tag: "v1") : nil
        try exec("BEGIN")
        do {
            try exec("""
            ALTER TABLE words ADD COLUMN lemma TEXT;
            ALTER TABLE words ADD COLUMN source_app TEXT;
            ALTER TABLE words ADD COLUMN source_title TEXT;
            ALTER TABLE words ADD COLUMN source_url TEXT;
            ALTER TABLE words ADD COLUMN note TEXT NOT NULL DEFAULT '';
            ALTER TABLE words ADD COLUMN book_id INTEGER;
            CREATE TABLE IF NOT EXISTS books(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL UNIQUE COLLATE NOCASE,
              is_default INTEGER NOT NULL DEFAULT 0,
              created REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS contexts(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              word_id INTEGER NOT NULL REFERENCES words(id) ON DELETE CASCADE,
              sentence TEXT NOT NULL,
              surface TEXT,
              source_app TEXT, source_title TEXT, source_url TEXT,
              added REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS contexts_word ON contexts(word_id);
            CREATE TABLE IF NOT EXISTS tags(
              word_id INTEGER NOT NULL REFERENCES words(id) ON DELETE CASCADE,
              tag TEXT NOT NULL COLLATE NOCASE,
              PRIMARY KEY(word_id, tag)
            );
            """)
            try run("INSERT INTO books(name, is_default, created) VALUES('生词本', 1, ?)", [Date()])
            let def = sqlite3_last_insert_rowid(db)
            try run("UPDATE words SET book_id = ?", [def])
            try exec("""
            INSERT INTO contexts(word_id, sentence, added)
              SELECT id, context, added FROM words WHERE context IS NOT NULL AND TRIM(context) <> '';
            """)
            try exec("PRAGMA user_version = 2")
            try exec("COMMIT")
            if existed && n > 0 { migrationV2 = (backup, n) }
        } catch { try? exec("ROLLBACK"); throw error }
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
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

    /// Run several writes atomically.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try exec("SAVEPOINT tx")
        do { let r = try body(); try exec("RELEASE tx"); return r }
        catch { try? exec("ROLLBACK TO tx"); try? exec("RELEASE tx"); throw error }
    }

    private static let columns = """
    id, word, definition, dictionary, context, added, ease, interval, reps, lapses, due, last_reviewed, stability, difficulty, state, step,
    lemma, source_app, source_title, source_url, note, book_id,
    (SELECT group_concat(tag, char(31)) FROM (SELECT tag FROM tags WHERE word_id = words.id ORDER BY tag)),
    (SELECT COUNT(*) FROM contexts WHERE word_id = words.id)
    """

    private static func text(_ st: OpaquePointer, _ i: Int32) -> String? { sqlite3_column_text(st, i).map { String(cString: $0) } }
    private static func date(_ st: OpaquePointer, _ i: Int32) -> Date? {
        sqlite3_column_type(st, i) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(st, i))
    }

    private static func item(_ st: OpaquePointer) -> WordItem {
        func num(_ i: Int32) -> Double? { sqlite3_column_type(st, i) == SQLITE_NULL ? nil : sqlite3_column_double(st, i) }
        var w = WordItem(
            id: sqlite3_column_int64(st, 0), word: text(st, 1) ?? "", definition: text(st, 2) ?? "",
            dictionary: text(st, 3) ?? "", context: text(st, 4), added: date(st, 5) ?? Date(),
            review: ReviewState(state: CardState(rawValue: Int(sqlite3_column_int64(st, 14))) ?? .new,
                                step: sqlite3_column_type(st, 15) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(st, 15)),
                                stability: num(12), difficulty: num(13),
                                intervalDays: sqlite3_column_double(st, 7),
                                repetitions: Int(sqlite3_column_int64(st, 8)), lapses: Int(sqlite3_column_int64(st, 9)),
                                due: date(st, 10) ?? Date(), lastReviewed: date(st, 11)))
        w.lemma = text(st, 16)
        w.sourceApp = text(st, 17); w.sourceTitle = text(st, 18); w.sourceURL = text(st, 19)
        w.note = text(st, 20) ?? ""
        w.bookID = sqlite3_column_type(st, 21) == SQLITE_NULL ? nil : sqlite3_column_int64(st, 21)
        w.tags = text(st, 22).map { $0.split(separator: "\u{1f}").map(String.init) } ?? []
        w.contextCount = Int(sqlite3_column_int64(st, 23))
        return w
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// Add a word, or update its definition if it is already in the book. A new context sentence is
    /// appended to the word's contexts (never overwriting older ones); the first source sticks.
    @discardableResult
    public func add(word: String, definition: String, dictionary: String, context: String? = nil,
                    surface: String? = nil, lemma: String? = nil, source: WordSource? = nil, book: Int64? = nil,
                    now: Date = Date()) throws -> WordItem {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let ctx = Self.clean(context)
        let lem = Self.clean(lemma).flatMap { $0.caseInsensitiveCompare(w) == .orderedSame ? nil : $0 }
        return try transaction {
            let bookID = try book ?? defaultBook().id
            try run("""
            INSERT INTO words(word, definition, dictionary, context, added, due, lemma, source_app, source_title, source_url, book_id)
              VALUES(?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(word) DO UPDATE SET
              definition = CASE WHEN excluded.definition <> '' THEN excluded.definition ELSE words.definition END,
              dictionary = CASE WHEN excluded.dictionary <> '' THEN excluded.dictionary ELSE words.dictionary END,
              context = words.context,
              lemma = COALESCE(words.lemma, excluded.lemma),
              source_app = COALESCE(words.source_app, excluded.source_app),
              source_title = COALESCE(words.source_title, excluded.source_title),
              source_url = COALESCE(words.source_url, excluded.source_url),
              book_id = COALESCE(words.book_id, excluded.book_id)
            """, [w, definition, dictionary, ctx, now, now, lem, Self.clean(source?.app), Self.clean(source?.title), Self.clean(source?.url), bookID])
            let item = try find(word: w)!
            if let ctx { try addContext(wordID: item.id, sentence: ctx, surface: surface, source: source, now: now) }
            return try find(word: w)!
        }
    }

    /// Append a context sentence unless the word already has the same one.
    public func addContext(wordID: Int64, sentence: String, surface: String? = nil, source: WordSource?, now: Date = Date()) throws {
        guard let s = Self.clean(sentence) else { return }
        var dup = 0
        try run("SELECT COUNT(*) FROM contexts WHERE word_id = ? AND sentence = ?", [wordID, s]) { dup = Int(sqlite3_column_int64($0, 0)) }
        guard dup == 0 else { return }
        try run("INSERT INTO contexts(word_id, sentence, surface, source_app, source_title, source_url, added) VALUES(?,?,?,?,?,?,?)",
                [wordID, s, Self.clean(surface), Self.clean(source?.app), Self.clean(source?.title), Self.clean(source?.url), now])
        try run("UPDATE words SET context = ? WHERE id = ?", [s, wordID])
    }

    /// All context sentences of a word, oldest first.
    public func contexts(for wordID: Int64) throws -> [WordContext] {
        var out: [WordContext] = []
        try run("SELECT id, word_id, sentence, surface, source_app, source_title, source_url, added FROM contexts WHERE word_id = ? ORDER BY added, id", [wordID]) { st in
            out.append(WordContext(id: sqlite3_column_int64(st, 0), wordID: sqlite3_column_int64(st, 1), sentence: Self.text(st, 2) ?? "", surface: Self.text(st, 3),
                                   sourceApp: Self.text(st, 4), sourceTitle: Self.text(st, 5), sourceURL: Self.text(st, 6),
                                   added: Self.date(st, 7) ?? Date()))
        }
        return out
    }

    public func deleteContext(id: Int64) throws {
        var wid: Int64?
        try run("SELECT word_id FROM contexts WHERE id = ?", [id]) { wid = sqlite3_column_int64($0, 0) }
        try run("DELETE FROM contexts WHERE id = ?", [id])
        if let wid {
            try run("UPDATE words SET context = (SELECT sentence FROM contexts WHERE word_id = ? ORDER BY added DESC, id DESC LIMIT 1) WHERE id = ?", [wid, wid])
        }
    }

    public func find(word: String) throws -> WordItem? {
        var out: WordItem?
        try run("SELECT \(Self.columns) FROM words WHERE word = ?", [word]) { out = Self.item($0) }
        return out
    }

    public func find(id: Int64) throws -> WordItem? {
        var out: WordItem?
        try run("SELECT \(Self.columns) FROM words WHERE id = ?", [id]) { out = Self.item($0) }
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
        UPDATE words SET word=?, definition=?, dictionary=?, context=?, interval=?, reps=?, lapses=?, due=?, last_reviewed=?,
          stability=?, difficulty=?, state=?, step=? WHERE id=?
        """, [item.word, item.definition, item.dictionary, item.context, item.review.intervalDays,
              item.review.repetitions, item.review.lapses, item.review.due, item.review.lastReviewed,
              item.review.stability, item.review.difficulty, item.review.state.rawValue, item.review.step, item.id])
    }

    public func delete(id: Int64) throws {
        try run("DELETE FROM words WHERE id = ?", [id])
    }

    /// Apply a review rating and persist the new schedule.
    @discardableResult
    public func review(id: Int64, rating: ReviewRating, now: Date = Date()) throws -> WordItem? {
        guard var it = try find(id: id) else { return nil }
        it.review = Scheduler.next(it.review, rating: rating, now: now)
        try update(it)
        return it
    }

    /// 斩: mark a word as mastered so it leaves the review rotation (kept in the wordbook).
    @discardableResult
    public func retire(id: Int64, now: Date = Date()) throws -> WordItem? {
        guard var it = try find(id: id) else { return nil }
        it.review = Scheduler.retire(it.review, now: now)
        try update(it)
        return it
    }

    public func count() throws -> Int {
        var n = 0
        try run("SELECT COUNT(*) FROM words", []) { n = Int(sqlite3_column_int64($0, 0)) }
        return n
    }

    // MARK: - Notes and tags

    public func setNote(id: Int64, _ note: String) throws {
        try run("UPDATE words SET note = ? WHERE id = ?", [note, id])
    }

    public func addTag(_ tag: String, to ids: [Int64]) throws {
        guard let t = Self.clean(tag) else { return }
        try transaction { for id in ids { try run("INSERT OR IGNORE INTO tags(word_id, tag) VALUES(?, ?)", [id, t]) } }
    }

    public func removeTag(_ tag: String, from ids: [Int64]) throws {
        try transaction { for id in ids { try run("DELETE FROM tags WHERE word_id = ? AND tag = ?", [id, tag]) } }
    }

    public func setTags(id: Int64, _ tags: [String]) throws {
        try transaction {
            try run("DELETE FROM tags WHERE word_id = ?", [id])
            for t in tags.compactMap(Self.clean) { try run("INSERT OR IGNORE INTO tags(word_id, tag) VALUES(?, ?)", [id, t]) }
        }
    }

    /// Every tag with its word count, alphabetical.
    public func allTags() throws -> [(tag: String, count: Int)] {
        var out: [(String, Int)] = []
        try run("SELECT tag, COUNT(*) FROM tags GROUP BY tag COLLATE NOCASE ORDER BY tag COLLATE NOCASE", []) {
            out.append((Self.text($0, 0) ?? "", Int(sqlite3_column_int64($0, 1))))
        }
        return out
    }

    // MARK: - Wordbooks (single level)

    public func books() throws -> [Wordbook] {
        var out: [Wordbook] = []
        try run("SELECT id, name, is_default FROM books ORDER BY is_default DESC, created, id", []) {
            out.append(Wordbook(id: sqlite3_column_int64($0, 0), name: Self.text($0, 1) ?? "", isDefault: sqlite3_column_int64($0, 2) != 0))
        }
        return out
    }

    public func defaultBook() throws -> Wordbook {
        if let b = try books().first(where: \.isDefault) { return b }
        if let b = try books().first { try setDefaultBook(b.id); return Wordbook(id: b.id, name: b.name, isDefault: true) }
        try run("INSERT INTO books(name, is_default, created) VALUES('生词本', 1, ?)", [Date()])
        return try books().first!
    }

    @discardableResult
    public func createBook(_ name: String) throws -> Wordbook {
        guard let n = Self.clean(name) else { throw WordStoreError.sql("empty name") }
        try run("INSERT INTO books(name, is_default, created) VALUES(?, 0, ?) ON CONFLICT(name) DO NOTHING", [n, Date()])
        return try books().first { $0.name.caseInsensitiveCompare(n) == .orderedSame }!
    }

    public func renameBook(_ id: Int64, to name: String) throws {
        guard let n = Self.clean(name) else { return }
        try run("UPDATE books SET name = ? WHERE id = ?", [n, id])
    }

    public func setDefaultBook(_ id: Int64) throws {
        try transaction {
            try run("UPDATE books SET is_default = 0", [])
            try run("UPDATE books SET is_default = 1 WHERE id = ?", [id])
        }
    }

    /// Delete a wordbook; its words move to the default wordbook (the default one can't be deleted).
    public func deleteBook(_ id: Int64) throws {
        let def = try defaultBook()
        guard id != def.id else { return }
        try transaction {
            try run("UPDATE words SET book_id = ? WHERE book_id = ?", [def.id, id])
            try run("DELETE FROM books WHERE id = ?", [id])
        }
    }

    public func move(_ ids: [Int64], toBook book: Int64) throws {
        try transaction { for id in ids { try run("UPDATE words SET book_id = ? WHERE id = ?", [book, id]) } }
    }
}

extension WordStore {
    /// Rename a word's stored spelling (case fix). Fails quietly if another row already has that spelling.
    public func renameWord(id: Int64, to word: String) throws {
        try run("UPDATE words SET word = ? WHERE id = ?", [word, id])
    }
    public func setDefinition(id: Int64, _ definition: String, dictionary: String? = nil) throws {
        if let dictionary { try run("UPDATE words SET definition = ?, dictionary = ? WHERE id = ?", [definition, dictionary, id]) }
        else { try run("UPDATE words SET definition = ? WHERE id = ?", [definition, id]) }
    }
}
