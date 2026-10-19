import CMultitouch
import XCTest
@testable import VocabCore

final class SchedulerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testGoodProgression() {
        var s = ReviewState.new(now: t0)
        s = Scheduler.next(s, rating: .good, now: t0)
        XCTAssertEqual(s.intervalDays, 1); XCTAssertEqual(s.repetitions, 1)
        s = Scheduler.next(s, rating: .good, now: t0)
        XCTAssertEqual(s.intervalDays, 6)
        s = Scheduler.next(s, rating: .good, now: t0)
        XCTAssertEqual(s.intervalDays, 15) // 6 × 2.5
        XCTAssertEqual(s.due, t0.addingTimeInterval(15 * 86_400))
    }

    func testForgotResetsAndRelearnsSoon() {
        var s = ReviewState.new(now: t0)
        s = Scheduler.next(s, rating: .good, now: t0)
        s = Scheduler.next(s, rating: .good, now: t0)
        s = Scheduler.next(s, rating: .forgot, now: t0)
        XCTAssertEqual(s.repetitions, 0); XCTAssertEqual(s.lapses, 1)
        XCTAssertEqual(s.ease, 2.3, accuracy: 1e-9)
        XCTAssertEqual(s.due, t0.addingTimeInterval(600))
    }

    func testFuzzyLowersEaseAndGrowsSlowly() {
        var s = ReviewState.new(now: t0)
        s = Scheduler.next(s, rating: .fuzzy, now: t0)
        XCTAssertEqual(s.intervalDays, 1)
        s = Scheduler.next(s, rating: .fuzzy, now: t0)
        XCTAssertEqual(s.intervalDays, 3)
        s = Scheduler.next(s, rating: .fuzzy, now: t0)
        XCTAssertEqual(s.intervalDays, 4)
        XCTAssertEqual(s.ease, 2.05, accuracy: 1e-9)
    }

    func testEaseFloor() {
        var s = ReviewState.new(now: t0)
        for _ in 0..<20 { s = Scheduler.next(s, rating: .forgot, now: t0) }
        XCTAssertEqual(s.ease, Scheduler.minEase)
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
        XCTAssertEqual(r.review.intervalDays, 1)
        XCTAssertEqual(try store.due(now: now.addingTimeInterval(5)).map(\.word), ["atlantic"])
        XCTAssertEqual(try store.due(now: now.addingTimeInterval(86_401)).count, 2)
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

    func testCSV() throws {
        let store = try WordStore(url: nil)
        try store.add(word: "say \"hi\"", definition: "a, b\nc", dictionary: "D", context: nil)
        let csv = CSVExporter.csv(try store.all())
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "word,definition,dictionary,context,added,due,interval_days,repetitions,lapses")
        XCTAssertTrue(lines[1].hasPrefix("\"say \"\"hi\"\"\",\"a, b\nc\",D,,"))
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

    func testSlowOrMovingOrTwoFingersIsNotATap() {
        _ = vmt_feed_frame(3, 0.5, 0.5, 0); XCTAssertEqual(vmt_feed_frame(0, 0, 0, 0.6), 0)
        _ = vmt_feed_frame(3, 0.5, 0.5, 0); _ = vmt_feed_frame(3, 0.6, 0.5, 0.05); XCTAssertEqual(vmt_feed_frame(0, 0, 0, 0.1), 0)
        _ = vmt_feed_frame(2, 0.5, 0.5, 0); XCTAssertEqual(vmt_feed_frame(0, 0, 0, 0.1), 0)
        _ = vmt_feed_frame(4, 0.5, 0.5, 0); XCTAssertEqual(vmt_feed_frame(0, 0, 0, 0.1), 0)
    }
}
