import SQLite3
import XCTest
@testable import VocabCore

/// All tests use in-memory or temp-dir stores; the real wordbook is never touched.
final class WordbookTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-wb-\(UUID())")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    func testContextsAccumulate() throws {
        let s = try WordStore(url: nil)
        let src = WordSource(app: "Safari", title: "BBC", url: "https://bbc.co.uk/a")
        try s.add(word: "appal", definition: "d", dictionary: "D", context: "It appals me.", surface: "appals", source: src, now: now)
        try s.add(word: "appal", definition: "d2", dictionary: "D", context: "We were appalled.", surface: "appalled",
                  source: WordSource(app: "Books"), now: now.addingTimeInterval(10))
        try s.add(word: "appal", definition: "d2", dictionary: "D", context: "It appals me.", now: now.addingTimeInterval(20))
        let w = try XCTUnwrap(s.find(word: "appal"))
        XCTAssertEqual(w.contextCount, 2)
        XCTAssertEqual(w.context, "We were appalled.")
        XCTAssertEqual(w.sourceApp, "Safari"); XCTAssertEqual(w.sourceURL, "https://bbc.co.uk/a")   // first source sticks
        XCTAssertEqual(w.sourceLabel, "BBC")
        let cs = try s.contexts(for: w.id)
        XCTAssertEqual(cs.map(\.surface), ["appals", "appalled"])
        XCTAssertEqual(cs[1].sourceApp, "Books")
        try s.deleteContext(id: cs[1].id)
        XCTAssertEqual(try s.find(word: "appal")?.context, "It appals me.")
        try s.delete(id: w.id)
        XCTAssertTrue(try s.contexts(for: w.id).isEmpty)   // cascade
    }

    func testMigratesV1WithBackupAndKeepsContext() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("vocab.sqlite")
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, """
        CREATE TABLE words(id INTEGER PRIMARY KEY AUTOINCREMENT, word TEXT NOT NULL UNIQUE COLLATE NOCASE,
          definition TEXT NOT NULL DEFAULT '', dictionary TEXT NOT NULL DEFAULT '', context TEXT, added REAL NOT NULL,
          ease REAL NOT NULL DEFAULT 2.5, interval REAL NOT NULL DEFAULT 0, reps INTEGER NOT NULL DEFAULT 0,
          lapses INTEGER NOT NULL DEFAULT 0, due REAL NOT NULL, last_reviewed REAL, stability REAL, difficulty REAL,
          state INTEGER NOT NULL DEFAULT 0, step INTEGER);
        INSERT INTO words(word, definition, context, added, due, stability, state, interval) VALUES('quay', 'wharf', 'On the quay.', 5, 9, 30, 2, 30);
        INSERT INTO words(word, added, due) VALUES('fresh', 6, 9);
        """, nil, nil, nil)
        sqlite3_close(db)
        let s = try WordStore(url: url)
        XCTAssertNil(s.migration)
        XCTAssertEqual(s.migrationV2?.words, 2)
        let b = try XCTUnwrap(s.migrationV2?.backup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
        let q = try XCTUnwrap(s.find(word: "quay"))
        XCTAssertEqual(q.definition, "wharf"); XCTAssertEqual(q.review.stability, 30)
        XCTAssertEqual(try s.contexts(for: q.id).map(\.sentence), ["On the quay."])
        let def = try s.defaultBook()
        XCTAssertEqual(def.name, "生词本")
        XCTAssertEqual(q.bookID, def.id)
        XCTAssertEqual(q.familiarity, .familiar)
        XCTAssertEqual(try s.find(word: "fresh")?.familiarity, .new)
        // The backup still has the old schema and data.
        let old = try WordStore(url: b)
        XCTAssertEqual(try old.count(), 2)
        XCTAssertNil(try WordStore(url: url).migrationV2)
    }

    func testFamiliarity() {
        func r(_ st: CardState, _ s: Double?, _ ivl: Double) -> ReviewState {
            ReviewState(state: st, step: nil, stability: s, difficulty: 5, intervalDays: ivl, repetitions: 1, lapses: 0, due: now, lastReviewed: now)
        }
        XCTAssertEqual(Familiarity(r(.new, nil, 0)), .new)
        XCTAssertEqual(Familiarity(r(.learning, 0.1, 0)), .learning)
        XCTAssertEqual(Familiarity(r(.review, 5, 5)), .learning)
        XCTAssertEqual(Familiarity(r(.review, 40, 40)), .familiar)
        XCTAssertEqual(Familiarity(r(.relearning, 40, 1)), .learning)
        XCTAssertEqual(Familiarity(Scheduler.retire(r(.learning, 1, 0), now: now)), .retired)
    }

    func testTagsNotesAndBooks() throws {
        let s = try WordStore(url: nil)
        let a = try s.add(word: "a1", definition: "", dictionary: "")
        let b = try s.add(word: "b1", definition: "", dictionary: "")
        try s.addTag("GRE", to: [a.id, b.id]); try s.addTag("gre", to: [a.id]); try s.addTag("考研", to: [b.id])
        XCTAssertEqual(try s.find(id: a.id)?.tags, ["GRE"])
        XCTAssertEqual(try s.allTags().map(\.tag), ["GRE", "考研"])
        XCTAssertEqual(try s.allTags().first?.count, 2)
        try s.removeTag("GRE", from: [b.id])
        XCTAssertEqual(try s.find(id: b.id)?.tags, ["考研"])
        try s.setNote(id: a.id, "**bold** note")
        XCTAssertEqual(try s.find(id: a.id)?.note, "**bold** note")
        let ielts = try s.createBook("雅思")
        XCTAssertEqual(try s.createBook("雅思").id, ielts.id)
        try s.move([a.id], toBook: ielts.id)
        XCTAssertEqual(try s.find(id: a.id)?.bookID, ielts.id)
        let c = try s.add(word: "c1", definition: "", dictionary: "", book: ielts.id)
        XCTAssertEqual(c.bookID, ielts.id)
        try s.setDefaultBook(ielts.id)
        XCTAssertEqual(try s.defaultBook().id, ielts.id)
        XCTAssertEqual(try s.add(word: "d1", definition: "", dictionary: "").bookID, ielts.id)
        let old = try XCTUnwrap(s.books().first { $0.name == "生词本" })
        try s.deleteBook(ielts.id)   // default: refused
        XCTAssertEqual(try s.books().count, 2)
        try s.setDefaultBook(old.id); try s.deleteBook(ielts.id)
        XCTAssertEqual(try s.books().map(\.name), ["生词本"])
        XCTAssertEqual(try s.find(id: a.id)?.bookID, old.id)   // words move to the default book
    }

    func testCSVRoundTrip() throws {
        let s = try WordStore(url: nil)
        let w = try s.add(word: "quay", definition: "a wharf, \"pier\"", dictionary: "D", context: "On the quay,\nat dawn.",
                          source: WordSource(app: "Safari", title: "T", url: "https://x.org/"), now: now)
        try s.addTag("港口", to: [w.id]); try s.addTag("GRE", to: [w.id]); try s.setNote(id: w.id, "n")
        let csv = CSVExporter.csv(try s.all(), books: try s.books())
        let t = try WordStore(url: nil)
        let r = try WordbookImporter.importCSV(csv, into: t)
        XCTAssertEqual(r.added, 1)
        let u = try XCTUnwrap(t.find(word: "quay"))
        XCTAssertEqual(u.definition, "a wharf, \"pier\"")
        XCTAssertEqual(u.context, "On the quay,\nat dawn.")
        XCTAssertEqual(u.sourceURL, "https://x.org/"); XCTAssertEqual(u.sourceTitle, "T")
        XCTAssertEqual(Set(u.tags), ["港口", "GRE"]); XCTAssertEqual(u.note, "n")
        XCTAssertEqual(u.added, now)
        // Headerless two-column CSV with a BOM.
        let r2 = try WordbookImporter.importCSV("\u{FEFF}moor,to tie up\r\nquay,wharf\r\n", into: t)
        XCTAssertEqual(r2.added, 1); XCTAssertEqual(r2.updated, 1)
        XCTAssertEqual(try t.find(word: "moor")?.definition, "to tie up")
    }

    func testCSVParser() {
        XCTAssertEqual(CSVParser.rows("a,\"b,\"\"c\"\"\"\n\nx,\r\n"), [["a", "b,\"c\""], ["x", ""]])
    }

    func testKindleImport() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("vocab.db")
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, """
        CREATE TABLE WORDS (id TEXT PRIMARY KEY NOT NULL, word TEXT, stem TEXT, lang TEXT, category INTEGER DEFAULT 0, timestamp INTEGER DEFAULT 0, profileid TEXT);
        CREATE TABLE LOOKUPS (id TEXT PRIMARY KEY NOT NULL, word_key TEXT, book_key TEXT, dict_key TEXT, pos TEXT, usage TEXT, timestamp INTEGER DEFAULT 0);
        CREATE TABLE BOOK_INFO (id TEXT PRIMARY KEY NOT NULL, asin TEXT, guid TEXT, lang TEXT, title TEXT, authors TEXT);
        INSERT INTO WORDS VALUES('en:appalled','appalled','appal','en',0,1700000000000,'');
        INSERT INTO BOOK_INFO VALUES('b1','A','g','en','Middlemarch','George Eliot');
        INSERT INTO LOOKUPS VALUES('l1','en:appalled','b1','d','1','She was appalled at it.',1700000000000);
        INSERT INTO LOOKUPS VALUES('l2','en:appalled','b1','d','2','Everyone was appalled.',1700000500000);
        """, nil, nil, nil)
        sqlite3_close(db)
        let s = try WordStore(url: nil)
        let r = try WordbookImporter.importKindle(at: url, into: s)
        XCTAssertEqual(r, ImportResult(added: 1, updated: 1, contexts: 2))
        let w = try XCTUnwrap(s.find(word: "appal"))
        XCTAssertEqual(w.sourceApp, "Kindle"); XCTAssertEqual(w.sourceTitle, "Middlemarch")
        XCTAssertEqual(w.added, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(try s.contexts(for: w.id).map(\.surface), ["appalled", "appalled"])
        // Re-import adds nothing new.
        XCTAssertEqual(try WordbookImporter.importKindle(at: url, into: s).contexts, 0)
    }

    func testCloze() {
        XCTAssertEqual(AnkiExporter.cloze(sentence: "We were appalled.", word: "appal"), "We were {{c1::appalled}}.")
        XCTAssertEqual(AnkiExporter.cloze(sentence: "On the Quay.", word: "quay", hint: "码头"), "On the {{c1::Quay::码头}}.")
        XCTAssertEqual(AnkiExporter.cloze(sentence: nil, word: "a<b"), "{{c1::a&lt;b}}")
        XCTAssertEqual(AnkiExporter.cloze(sentence: "No match here.", word: "zeal"), "No match here.<br>{{c1::zeal}}")
    }

    func testAnkiPackage() throws {
        let dir = try tempDir()
        let s = try WordStore(url: nil)
        let w = try s.add(word: "appal", definition: "to shock", dictionary: "D", context: "We were appalled.", now: now)
        try s.addTag("GRE words", to: [w.id])
        try s.add(word: "quay", definition: "wharf", dictionary: "D", now: now)
        let out = dir.appendingPathComponent("v.apkg")
        try AnkiExporter.write(try s.all(), deckName: "生词本", to: out, now: now)
        // Unzip with the system tool to prove the archive is valid.
        let x = dir.appendingPathComponent("x")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = ["-q", out.path, "-d", x.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: x.appendingPathComponent("media"), encoding: .utf8), "{}")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(x.appendingPathComponent("collection.anki2").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        func rows(_ sql: String) -> [[String]] {
            var st: OpaquePointer?; sqlite3_prepare_v2(db, sql, -1, &st, nil); defer { sqlite3_finalize(st) }
            var out: [[String]] = []
            while sqlite3_step(st) == SQLITE_ROW {
                out.append((0..<sqlite3_column_count(st)).map { sqlite3_column_text(st, $0).map { String(cString: $0) } ?? "" })
            }
            return out
        }
        XCTAssertEqual(rows("SELECT ver FROM col"), [["11"]])
        let notes = rows("SELECT flds, tags FROM notes ORDER BY id")
        XCTAssertEqual(notes.count, 2)
        XCTAssertTrue(notes.contains { $0[0].hasPrefix("We were {{c1::appalled::to shock}}.\u{1f}<b>appal</b>") && $0[1] == " GRE_words Vocab " })
        XCTAssertTrue(notes.contains { $0[0].hasPrefix("{{c1::quay::wharf}}\u{1f}") })
        XCTAssertEqual(rows("SELECT COUNT(*) FROM cards c JOIN notes n ON n.id = c.nid"), [["2"]])
        let models = try XCTUnwrap(rows("SELECT models FROM col").first?.first)
        XCTAssertTrue(models.contains("{{cloze:Text}}"))
    }

    func testLemma() {
        XCTAssertEqual(Lemmatizer.lemma(of: "running", in: "She was running fast."), "run")
        XCTAssertNil(Lemmatizer.lemma(of: "run"))
    }
}
