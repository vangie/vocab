import CMultitouch
import SQLite3
import XCTest
@testable import VocabCore

final class SchedulerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_669_725_000)   // 2022-11-29 12:30 UTC, as in py-fsrs tests
    let fsrs = FSRS()

    /// Reference vector from the official py-fsrs test suite (FSRS-6 defaults, no fuzz):
    /// G G G G G G A A G G G G G → intervals 0 2 11 46 163 498 0 0 2 4 7 12 21 days.
    func testReferenceIntervals() {
        let ratings: [ReviewRating] = [.good, .good, .good, .good, .good, .good, .forgot, .forgot, .good, .good, .good, .good, .good]
        var c = ReviewState.new(now: t0); var t = t0; var ivl: [Int] = []
        for g in ratings {
            c = fsrs.next(c, rating: g, now: t)
            ivl.append(Int(floor(c.due.timeIntervalSince(c.lastReviewed!) / 86_400)))
            t = c.due
        }
        XCTAssertEqual(ivl, [0, 2, 11, 46, 163, 498, 0, 0, 2, 4, 7, 12, 21])
    }

    /// py-fsrs test_memo_state: A G G G G G reviewed after 0 0 1 3 8 21 days → S 53.62691, D 6.3574867.
    func testReferenceMemoryState() {
        var c = ReviewState.new(now: t0); var t = t0
        for (g, d) in zip([ReviewRating.forgot, .good, .good, .good, .good, .good], [0.0, 0, 1, 3, 8, 21]) {
            t = t.addingTimeInterval(d * 86_400)
            c = fsrs.next(c, rating: g, now: t)
        }
        XCTAssertEqual(c.stability!, 53.62691, accuracy: 1e-4)
        XCTAssertEqual(c.difficulty!, 6.3574867, accuracy: 1e-4)
    }

    /// py-fsrs test_repeated_correct_reviews: ten Easy in a row drive difficulty to 1.
    func testRepeatedEasy() {
        var c = ReviewState.new(now: t0)
        for i in 0..<10 { c = fsrs.next(c, rating: .easy, now: t0.addingTimeInterval(Double(i) * 1e-6)) }
        XCTAssertEqual(c.difficulty!, 1.0, accuracy: 1e-9)
    }

    func testFirstReviewInitialValues() {
        for g in ReviewRating.allCases {
            let c = fsrs.next(.new(now: t0), rating: g, now: t0)
            XCTAssertEqual(c.stability!, FSRS.defaultParameters[g.rawValue - 1], accuracy: 1e-9)
        }
        let good = fsrs.next(.new(now: t0), rating: .good, now: t0)
        XCTAssertEqual(good.state, .learning); XCTAssertEqual(good.due, t0.addingTimeInterval(600))
        let easy = fsrs.next(.new(now: t0), rating: .easy, now: t0)
        XCTAssertEqual(easy.state, .review); XCTAssertEqual(easy.intervalDays, 8)   // S0(Easy) = 8.2956
        XCTAssertEqual(fsrs.next(.new(now: t0), rating: .forgot, now: t0).due, t0.addingTimeInterval(60))
        XCTAssertEqual(fsrs.next(.new(now: t0), rating: .fuzzy, now: t0).due, t0.addingTimeInterval(330))
    }

    func testDesiredRetentionAndLapse() {
        var f = FSRS(); f.desiredRetention = 0.9
        XCTAssertEqual(f.nextIntervalDays(10), 10)            // R = 0.9 at t = S by definition
        f.desiredRetention = 0.8
        XCTAssertGreaterThan(f.nextIntervalDays(10), 10)
        var c = ReviewState(state: .review, stability: 20, difficulty: 5, intervalDays: 20, repetitions: 5, due: t0,
                            lastReviewed: t0.addingTimeInterval(-20 * 86_400))
        c = fsrs.next(c, rating: .forgot, now: t0)
        XCTAssertEqual(c.state, .relearning); XCTAssertEqual(c.lapses, 1)
        XCTAssertLessThan(c.stability!, 20)
    }

    func testMigrationFromSM2() {
        let n = Scheduler.migrate(ease: 2.5, intervalDays: 0, repetitions: 0, lapses: 0, due: t0, lastReviewed: nil)
        XCTAssertEqual(n.state, .new); XCTAssertNil(n.stability)
        let r = Scheduler.migrate(ease: 2.5, intervalDays: 15, repetitions: 3, lapses: 0, due: t0, lastReviewed: t0)
        XCTAssertEqual(r.state, .review); XCTAssertEqual(r.stability, 15); XCTAssertEqual(r.difficulty!, 5, accuracy: 1e-9)
        let hard = Scheduler.migrate(ease: 1.3, intervalDays: 0, repetitions: 0, lapses: 2, due: t0, lastReviewed: t0)
        XCTAssertEqual(hard.state, .relearning); XCTAssertEqual(hard.difficulty!, 9, accuracy: 1e-9)
    }
}

final class WordStoreTests: XCTestCase {
    func testCRUDAndReview() throws {
        let store = try WordStore(url: nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = try store.add(word: "appal", definition: "to shock", dictionary: "LDOCE5", context: "It appals me.", now: now)
        try store.add(word: "atlantic", definition: "ocean", dictionary: "LDOCE5", now: now.addingTimeInterval(1))
        XCTAssertEqual(try store.count(), 2)
        // Upsert keeps one row, updates definition, keeps old context when none given.
        try store.add(word: "Appal", definition: "to shock badly", dictionary: "Macmillan", now: now)
        XCTAssertEqual(try store.count(), 2)
        let found = try XCTUnwrap(store.find(word: "appal"))
        XCTAssertEqual(found.id, a.id)
        XCTAssertEqual(found.definition, "to shock badly")
        XCTAssertEqual(found.context, "It appals me.")
        // New words are due immediately.
        XCTAssertEqual(try store.due(now: now.addingTimeInterval(5)).count, 2)
        let r = try XCTUnwrap(store.review(id: a.id, rating: .good, now: now))
        XCTAssertEqual(r.review.state, .learning)                     // FSRS learning step: 10 min
        XCTAssertEqual(try store.find(word: "appal")?.review, r.review)  // round-trips through SQLite
        XCTAssertEqual(try store.due(now: now.addingTimeInterval(5)).map(\.word), ["atlantic"])
        XCTAssertEqual(try store.due(now: now.addingTimeInterval(601)).count, 2)
        try store.delete(id: a.id)
        XCTAssertNil(try store.find(word: "appal"))
        XCTAssertEqual(try store.all().map(\.word), ["atlantic"])
    }

    func testPersistsToDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-test-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do { let s = try WordStore(url: url); try s.add(word: "quay", definition: "d", dictionary: "x") }
        let s2 = try WordStore(url: url)
        XCTAssertEqual(try s2.find(word: "quay")?.definition, "d")
    }

    func testMigratesSM2DatabaseWithBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-mig-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("vocab.sqlite")
        // An old-schema (SM-2) wordbook.
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, """
        CREATE TABLE words(id INTEGER PRIMARY KEY AUTOINCREMENT, word TEXT NOT NULL UNIQUE COLLATE NOCASE,
          definition TEXT NOT NULL DEFAULT '', dictionary TEXT NOT NULL DEFAULT '', context TEXT, added REAL NOT NULL,
          ease REAL NOT NULL DEFAULT 2.5, interval REAL NOT NULL DEFAULT 0, reps INTEGER NOT NULL DEFAULT 0,
          lapses INTEGER NOT NULL DEFAULT 0, due REAL NOT NULL, last_reviewed REAL);
        INSERT INTO words(word, added, due) VALUES('fresh', 0, 0);
        INSERT INTO words(word, added, ease, interval, reps, due, last_reviewed) VALUES('known', 0, 2.2, 12, 3, 100, 50);
        """, nil, nil, nil)
        sqlite3_close(db)
        let s = try WordStore(url: url)
        XCTAssertEqual(s.migration?.cards, 2)
        let backup = try XCTUnwrap(s.migration?.backup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(backup.deletingLastPathComponent().path, dir.path)
        XCTAssertEqual(try s.find(word: "fresh")?.review.state, .new)
        let k = try XCTUnwrap(s.find(word: "known")?.review)
        XCTAssertEqual(k.state, .review); XCTAssertEqual(k.stability, 12); XCTAssertEqual(k.difficulty!, 6, accuracy: 1e-9)
        // Second open: nothing to migrate.
        XCTAssertNil(try WordStore(url: url).migration)
    }

    func testCSV() throws {
        let store = try WordStore(url: nil)
        try store.add(word: "say \"hi\"", definition: "a, b\nc", dictionary: "D", context: nil)
        let csv = CSVExporter.csv(try store.all())
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], CSVExporter.header.joined(separator: ","))
        XCTAssertTrue(lines[1].hasPrefix("\"say \"\"hi\"\"\",,\"a, b\nc\",D,,"))
    }
}

final class FakePrefs: PreferenceStore {
    var values: [String: Int] = [:]
    var activations = 0
    func k(_ d: String, _ key: String, _ h: Bool) -> String { "\(h)|\(d)|\(key)" }
    func readInt(domain: String, key: String, currentHost: Bool) -> Int? { values[k(domain, key, currentHost)] }
    func write(domain: String, key: String, currentHost: Bool, value: Int?) { values[k(domain, key, currentHost)] = value }
    func activate() { activations += 1 }
}

final class TakeoverTests: XCTestCase {
    func testEngageAndRestore() {
        let prefs = FakePrefs()
        let defaults = UserDefaults(suiteName: "vocab-test-\(UUID())")!
        let keys = TrackpadTakeover.keys
        prefs.write(domain: keys[0].domain, key: keys[0].key, currentHost: false, value: 2)
        prefs.write(domain: keys[2].domain, key: keys[2].key, currentHost: true, value: 2)
        // keys[1] intentionally missing.
        let t = TrackpadTakeover(prefs: prefs, defaults: defaults)
        XCTAssertFalse(t.isEngaged)
        t.engage()
        XCTAssertTrue(t.isEngaged)
        for k in keys { XCTAssertEqual(prefs.readInt(domain: k.domain, key: k.key, currentHost: k.currentHost), 0) }
        t.engage() // second engage must not overwrite the saved originals
        t.restore()
        XCTAssertFalse(t.isEngaged)
        XCTAssertEqual(prefs.readInt(domain: keys[0].domain, key: keys[0].key, currentHost: false), 2)
        XCTAssertNil(prefs.readInt(domain: keys[1].domain, key: keys[1].key, currentHost: false))
        XCTAssertEqual(prefs.readInt(domain: keys[2].domain, key: keys[2].key, currentHost: true), 2)
        XCTAssertEqual(prefs.activations, 3)
    }
}

final class EntryHTMLTests: XCTestCase {
    func testContainerPathMapping() {
        let u = URL(fileURLWithPath: "/Users/x/Library/Containers/com.apple.Dictionary/Data/Library/Dictionaries/LDOCE5.dictionary/Contents/Resources/KeyText.index")
        XCTAssertEqual(EntryHTML.mapContainerPath(u, home: "/Users/x").path,
                       "/Users/x/Library/Dictionaries/LDOCE5.dictionary/Contents/Resources/KeyText.index")
    }

    func testPrepareRewritesBaseAndNamespace() {
        let html = #"<?xml version="1.0"?><html xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng"><head><base href="file:///a/B.dictionary/Contents/KeyText.index" /><style>x</style></head><body/></html>"#
        let dir = EntryHTML.resourceDirectory(fromHTML: html, bundleURL: nil)!
        XCTAssertEqual(dir.path, "/a/B.dictionary/Contents")
        let out = EntryHTML.prepare(html, resourceDirectory: dir)
        XCTAssertTrue(out.contains(#"<base href="vocab://file/a/B.dictionary/Contents/" />"#))
        XCTAssertTrue(out.contains(#"<html xmlns="http://www.w3.org/1999/xhtml" xmlns:d="#))
        XCTAssertTrue(out.contains("color-scheme"))
    }

    func testAudioReferencesBothForms() {
        let html = #"<a href="javascript:new Audio(&quot;media/english/breProns/x.mp3&quot;).play();">a</a><audio id="s" src="Sounds/y.mp3"/>"#
        XCTAssertEqual(EntryHTML.audioReferences(in: html), ["media/english/breProns/x.mp3", "Sounds/y.mp3"])
    }

    func testLocalFile() {
        let u = URL(string: "vocab://file/Users/x/Library/Dictionaries/L.dictionary/Contents/Resources/a%20b.mp3")!
        XCTAssertEqual(EntryHTML.localFile(for: u)?.path, "/Users/x/Library/Dictionaries/L.dictionary/Contents/Resources/a b.mp3")
    }

    func testLookupLinks() {
        XCTAssertEqual(EntryHTML.lookupWord(fromLink: URL(string: "x-dictionary:d:several#several__3__a")!), "several")
        XCTAssertEqual(EntryHTML.lookupWord(fromLink: URL(string: "x-dictionary:d:able%20seaman")!), "able seaman")
        XCTAssertNil(EntryHTML.lookupWord(fromLink: URL(string: "https://example.com")!))
    }

    func testWordBoundaries() {
        let r = WordUnderCursor.word(in: "We crossed the Atlantic. It was rough.", at: 17)
        XCTAssertEqual(r?.word, "Atlantic")
        XCTAssertEqual(r?.context, "We crossed the Atlantic.")
    }
}

final class TapDetectorTests: XCTestCase {
    override func setUp() { vmt_reset_state(); vmt_set_thresholds(0.35, 0.03) }

    func testThreeFingerTap() {
        XCTAssertEqual(vmt_feed_frame(1, 0.5, 0.5, 0.00), 0)
        XCTAssertEqual(vmt_feed_frame(3, 0.5, 0.5, 0.02), 0)
        XCTAssertEqual(vmt_feed_frame(3, 0.505, 0.5, 0.10), 0)
        XCTAssertEqual(vmt_feed_frame(0, 0, 0, 0.15), 1)
    }

    func testActiveCountIgnoresLiftingContacts() {
        // MakeTouch=3, Touching=4 count; BreakTouch=5, Linger=6, OutOfRange=7 do not.
        XCTAssertEqual(vmt_active_count([4, 4, 3], 3), 3)
        XCTAssertEqual(vmt_active_count([5, 6, 7], 3), 0)
    }

    func testSlowOrMovingOrTwoFingersIsNotATap() {
        _ = vmt_feed_frame(3, 0.5, 0.5, 0); XCTAssertEqual(vmt_feed_frame(0, 0, 0, 0.6), 0)
        _ = vmt_feed_frame(3, 0.5, 0.5, 0); _ = vmt_feed_frame(3, 0.6, 0.5, 0.05); XCTAssertEqual(vmt_feed_frame(0, 0, 0, 0.1), 0)
        _ = vmt_feed_frame(2, 0.5, 0.5, 0); XCTAssertEqual(vmt_feed_frame(0, 0, 0, 0.1), 0)
        _ = vmt_feed_frame(4, 0.5, 0.5, 0); XCTAssertEqual(vmt_feed_frame(0, 0, 0, 0.1), 0)
    }
}
