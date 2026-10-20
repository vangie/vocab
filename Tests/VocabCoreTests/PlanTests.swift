import SQLite3
import XCTest
@testable import VocabCore

final class PlanTests: XCTestCase {
    func testDailyLimits() {
        var p = StudyPlan()
        XCTAssertEqual(p.dailyNew, 20); XCTAssertEqual(p.dailyReview, 20)
        XCTAssertEqual(PlanMath.newToday(plan: p, due: 5, introducedToday: 0), 15)     // review limit − due
        XCTAssertEqual(PlanMath.reviewsToday(plan: p, due: 250), 20)
        p.dailyReview = 200
        XCTAssertEqual(PlanMath.newToday(plan: p, due: 10, introducedToday: 0), 20)
        XCTAssertEqual(PlanMath.newToday(plan: p, due: 190, introducedToday: 0), 10)
        XCTAssertEqual(PlanMath.newToday(plan: p, due: 250, introducedToday: 0), 0)
        XCTAssertEqual(PlanMath.newToday(plan: p, due: 0, introducedToday: 15), 5)
        XCTAssertEqual(PlanMath.reviewsToday(plan: p, due: 250), 200)
        p.dailyNew = 0
        XCTAssertEqual(PlanMath.newToday(plan: p, due: 0, introducedToday: 0), 0)
    }

    func testProjection() {
        var p = StudyPlan(); p.dailyNew = 20
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        p.targetDate = Calendar.current.date(byAdding: .day, value: 10, to: now)
        let r = PlanMath.projection(remaining: 450, plan: p, now: now)
        XCTAssertEqual(r.days, 23)
        XCTAssertEqual(r.neededPerDay, 45)
    }

    func testMixByRatioAndExhaustion() {
        let a = PlanMixer.Queue(id: .list(.ielts), ratio: 3, words: (0..<100).map { "a\($0)" })
        let b = PlanMixer.Queue(id: .list(.gre), ratio: 1, words: (0..<100).map { "b\($0)" })
        let m = PlanMixer.mix([a, b], count: 20, wordbookFirst: false)
        XCTAssertEqual(m.count, 20)
        XCTAssertEqual(m.filter { $0.source == .list(.ielts) }.count, 15)
        // Interleaved, not 15 then 5.
        XCTAssertTrue(m.prefix(4).contains { $0.source == .list(.gre) })
        // b runs out after 2: its share goes to a.
        let short = PlanMixer.Queue(id: .list(.gre), ratio: 1, words: ["b0", "b1"])
        let m2 = PlanMixer.mix([PlanMixer.Queue(id: .list(.ielts), ratio: 1, words: a.words), short], count: 10, wordbookFirst: false)
        XCTAssertEqual(m2.count, 10); XCTAssertEqual(m2.filter { $0.source == .list(.gre) }.count, 2)
    }

    func testMixGlobalPoolAndWordbookFirst() {
        let book = PlanMixer.Queue(id: .book(1), ratio: 1, words: ["quay", "moor"])
        let l1 = PlanMixer.Queue(id: .list(.cet4), ratio: 1, words: ["quay", "apple", "known", "bear"])
        let l2 = PlanMixer.Queue(id: .list(.cet6), ratio: 1, words: ["apple", "cede", "dire"])
        let m = PlanMixer.mix([l1, l2, book], count: 6, exclude: ["known"])
        XCTAssertEqual(m.prefix(2).map(\.word), ["quay", "moor"])          // wordbook first
        XCTAssertEqual(Set(m.map(\.word)).count, m.count)                 // each word once
        XCTAssertFalse(m.contains { $0.word == "known" })                 // learned / 斩 / skipped
        XCTAssertEqual(Set(m.map(\.word)), ["quay", "moor", "apple", "bear", "cede", "dire"])
        // Without priority, book and lists share by ratio.
        let n = PlanMixer.mix([l1, book], count: 2, wordbookFirst: false)
        XCTAssertEqual(Set(n.map(\.source)), [.book(1), .list(.cet4)])
    }

    func testOldDefaultReviewLimitMigrates() throws {
        let old = #"{"sources":[],"dailyNew":25,"dailyReview":200,"wordbookFirst":true,"configured":true}"#
        let p = try JSONDecoder().decode(StudyPlan.self, from: Data(old.utf8))
        XCTAssertEqual(p.dailyReview, 20); XCTAssertEqual(p.dailyNew, 25); XCTAssertTrue(p.configured)
        let custom = #"{"dailyReview":150}"#
        XCTAssertEqual(try JSONDecoder().decode(StudyPlan.self, from: Data(custom.utf8)).dailyReview, 150)
        var mine = StudyPlan(); mine.dailyReview = 200; mine.reviewEdited = true
        XCTAssertEqual(try JSONDecoder().decode(StudyPlan.self, from: JSONEncoder().encode(mine)).dailyReview, 200)
    }

    func testTargetLinkage() {
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = cal.startOfDay(for: now)
        var p = StudyPlan(); p.dailyReview = 200
        // Target → daily new.
        PlanMath.setTarget(&p, preset: .quarter, remaining: 4500, now: now, calendar: cal)
        XCTAssertEqual(p.dailyNew, 50)
        XCTAssertEqual(p.targetDate, cal.date(byAdding: .day, value: 90, to: today))
        PlanMath.setTarget(&p, preset: .month, remaining: 100, now: now, calendar: cal)
        XCTAssertEqual(p.dailyNew, 4)                                             // ceil(100/30)
        PlanMath.setTarget(&p, preset: .month, remaining: 90_000, now: now, calendar: cal)
        XCTAssertEqual(p.dailyNew, 500)                                           // clamped
        // Daily new → date.
        PlanMath.setTarget(&p, preset: .quarter, remaining: 4500, now: now, calendar: cal)
        p.dailyNew = 25
        PlanMath.limitsChanged(&p, remaining: 4500, due: 0, now: now, calendar: cal)
        XCTAssertEqual(p.targetDate, cal.date(byAdding: .day, value: 180, to: today))
        XCTAssertEqual(p.targetPreset, .half)
        // Review limit constrains the effective new words → date moves out.
        p.dailyReview = 30
        PlanMath.limitsChanged(&p, remaining: 4500, due: 15, now: now, calendar: cal)
        XCTAssertEqual(PlanMath.effectiveNew(plan: p, due: 15), 15)
        XCTAssertEqual(p.targetDate, cal.date(byAdding: .day, value: 300, to: today))
        XCTAssertEqual(p.targetPreset, .custom)
        // Custom date.
        let d = cal.date(byAdding: .day, value: 45, to: today)!
        PlanMath.setTarget(&p, preset: .custom, date: d, remaining: 4500, now: now, calendar: cal)
        XCTAssertEqual(p.dailyNew, 100); XCTAssertEqual(p.targetDate, d)
        // No target: limits don't touch a date.
        PlanMath.setTarget(&p, preset: nil, remaining: 4500, now: now, calendar: cal)
        PlanMath.limitsChanged(&p, remaining: 4500, due: 0, now: now, calendar: cal)
        XCTAssertNil(p.targetDate)
        XCTAssertNil(PlanMath.projectedDate(remaining: 10, plan: p, due: 999, now: now, calendar: cal))
    }

    func testRatios() {
        XCTAssertEqual(PlanRatios.equal(3), [35, 35, 30])
        XCTAssertEqual(PlanRatios.equal(1), [100])
        XCTAssertEqual(PlanRatios.snap([1, 1]), [50, 50])
        XCTAssertEqual(PlanRatios.snap([3, 1]), [75, 25])
        XCTAssertEqual(PlanRatios.snap([1, 1, 1]).reduce(0, +), 100)
        XCTAssertEqual(PlanRatios.snap([100, 0.01]), [95, 5])
        let r = [40.0, 30, 30]
        XCTAssertEqual(PlanRatios.moveDivider(r, after: 0, to: 52), [50, 20, 30])     // snaps to 5%
        XCTAssertEqual(PlanRatios.moveDivider(r, after: 0, to: 99), [65, 5, 30])      // neighbour keeps 5%
        XCTAssertEqual(PlanRatios.moveDivider(r, after: 1, to: 0), [40, 5, 55])
        XCTAssertEqual(PlanRatios.nudge(r, 2, by: 5), [40, 25, 35])
        XCTAssertEqual(PlanRatios.nudge([95, 5], 0, by: 5), [95, 5])
    }

    func testPlanPersists() {
        let d = UserDefaults(suiteName: "vocab-plan-\(UUID())")!
        var p = StudyPlan(); p.sources = [PlanSource(id: .list(.ielts), ratio: 2), PlanSource(id: .book(3), enabled: false)]
        p.dailyNew = 30; p.save(d)
        XCTAssertEqual(StudyPlan.load(d), p)
    }

    // MARK: word lists

    func testBundledListsAndPseudowords() throws {
        let lists = try XCTUnwrap(WordLists.shared)
        let e = try XCTUnwrap(lists.entry("abandon"))
        XCTAssertTrue(e.lists.contains(.cet4)); XCTAssertTrue(e.lists.contains(.toefl)); XCTAssertFalse(e.lists.contains(.zk))
        XCTAssertGreaterThan(e.rank, 0)
        XCTAssertNotNil(lists.shortChinese("abandon"))
        XCTAssertGreaterThan(lists.count(in: .gre), 3000)
        let ws = lists.words(in: .cet4)
        XCTAssertEqual(ws.first.flatMap { lists.entry($0) }.map { $0.rank < 200 }, true)  // common first
        let ps = lists.pseudowords()
        XCTAssertGreaterThanOrEqual(ps.count, 300)
        for p in ps { XCTAssertFalse(lists.contains(p), p) }
        // Pseudowords aren't in the system dictionaries either (where available).
        let dicts = DictionaryService.shared.activeDictionaries()
        if !dicts.isEmpty {
            let hits = ps.prefix(80).filter { DictionaryService.shared.hasEntry($0, in: dicts) }
            XCTAssertLessThanOrEqual(hits.count, 2, "\(hits)")
        }
    }

    // MARK: vocabulary test

    func testISDT() {
        XCTAssertEqual(VocabTestScoring.isdt(hit: 1, falseAlarm: 0), 1)
        XCTAssertEqual(VocabTestScoring.isdt(hit: 0.3, falseAlarm: 0.5), 0)
        XCTAssertEqual(VocabTestScoring.corrected(hit: 0.8, falseAlarm: 0), 0.8)
        XCTAssertLessThan(VocabTestScoring.corrected(hit: 0.8, falseAlarm: 0.3), 0.8)
        XCTAssertLessThan(VocabTestScoring.corrected(hit: 0.8, falseAlarm: 0.5), VocabTestScoring.corrected(hit: 0.8, falseAlarm: 0.2))
    }

    func run(_ knows: (Int) -> Bool, claimPseudo: Bool) -> VocabTestRun {
        let bands = (0..<10).map { VocabBand(lo: $0 * 1000 + 1, hi: ($0 + 1) * 1000, size: 1000) }
        let pool = (0..<10).map { b in (0..<40).map { "w\(b)_\($0)" } }
        var rng = SystemRandomNumberGenerator()
        var r = VocabTestRun(bands: bands, pool: pool, pseudo: (0..<60).map { "p\($0)" }, using: &rng)
        func answerAll() { while let it = r.current { r.answer(it.band.map(knows) ?? claimPseudo) } }
        answerAll()
        XCTAssertTrue(r.startRound2(using: &rng))
        answerAll()
        return r
    }

    func testRoundsAndScoring() {
        // Knows everything below rank 4000, nothing above.
        let r = run({ $0 < 4 }, claimPseudo: false)
        XCTAssertEqual(r.items.filter { $0.band != nil }.count, 40 + 10)
        let pseudo = r.items.filter { $0.band == nil }.count
        XCTAssertEqual(Double(pseudo) / Double(r.items.count), 0.15, accuracy: 0.03)
        let res = r.result()
        XCTAssertEqual(res.estimate, 4000)
        XCTAssertLessThanOrEqual(res.low, 4000); XCTAssertGreaterThanOrEqual(res.high, 4000)
        XCTAssertEqual(res.knownBands, [0, 1, 2, 3])
        XCTAssertEqual(res.falseAlarm, 0)
        // A yes-to-everything user is caught by the pseudowords.
        let liar = run({ _ in true }, claimPseudo: true).result()
        XCTAssertEqual(liar.falseAlarm, 1); XCTAssertEqual(liar.estimate, 0)
    }

    func testFocusBands() {
        var items: [VocabTestItem] = []
        let rates = [1, 1, 1, 0.75, 0.5, 0.25, 0, 0, 0, 0]
        for (b, r) in rates.enumerated() { for i in 0..<4 { items.append(VocabTestItem(word: "\(b)\(i)", band: b, known: Double(i) < r * 4)) } }
        let f = VocabTestScoring.focusBands(items, bandCount: 10)
        XCTAssertTrue((2...3).contains(f.count))
        XCTAssertTrue(f.contains(4)); XCTAssertTrue(f.allSatisfy { (3...5).contains($0) })
    }

    // MARK: store

    func testBulkRetireUndoAndExclusions() throws {
        let s = try WordStore(url: nil)
        let a = try s.add(word: "apple", definition: "", dictionary: "")
        _ = try s.review(id: a.id, rating: .good)
        let before = try XCTUnwrap(s.find(id: a.id)).review
        let b = try s.bulkRetire(["apple", "bear", "cede"], label: "词汇量测试")
        XCTAssertEqual(b.count, 3)
        XCTAssertEqual(try s.find(id: a.id)?.familiarity, .retired)
        XCTAssertEqual(try s.count(), 1)                                   // no flooding
        XCTAssertEqual(try s.planExclusions(), ["apple", "bear", "cede"])
        XCTAssertEqual(try s.latestBatch()?.id, b.id)
        try s.undoBatch(b.id)
        XCTAssertEqual(try s.find(id: a.id)?.review, before)
        XCTAssertEqual(try s.planExclusions(), ["apple"])                 // still learning → not new
        XCTAssertNil(try s.latestBatch())
    }

    func testResultHistoryAndV3Migration() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-v3-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("vocab.sqlite")
        do { let s = try WordStore(url: url); try s.add(word: "quay", definition: "d", dictionary: "x") }
        // Simulate a schema-2 file.
        var db: OpaquePointer?
        sqlite3_open(url.path, &db); sqlite3_exec(db, "DROP TABLE test_results; PRAGMA user_version = 2;", nil, nil, nil); sqlite3_close(db)
        let s = try WordStore(url: url)
        let b = try XCTUnwrap(s.migrationV3Backup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
        XCTAssertEqual(try s.find(word: "quay")?.definition, "d")
        let r = VocabTestResult(date: Date(timeIntervalSince1970: 1_800_000_000), estimate: 5200, low: 4800, high: 5600, falseAlarm: 0.1,
                                bands: [], bandRanges: [], knownBands: [0], checkBands: [3])
        try s.saveTestResult(r)
        XCTAssertEqual(try s.testResults(), [r])
    }
}
