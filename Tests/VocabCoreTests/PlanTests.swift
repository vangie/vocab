import SQLite3
import XCTest
@testable import VocabCore

final class PlanTests: XCTestCase {
    func testDailyLimits() {
        var p = StudyPlan()
        XCTAssertEqual(p.dailyNew, 20); XCTAssertTrue(p.reviewAuto); XCTAssertEqual(p.dailyReview, PlanMath.autoReviewLimit(dailyNew: 20))
        XCTAssertEqual(p.dailyReview % 10, 0)
        XCTAssertGreaterThanOrEqual(p.dailyReview, PlanMath.estimatedDailyReviews(dailyNew: 20))   // 自动 = load rounded up to 10
        p.dailyNew = 30; XCTAssertEqual(p.dailyReview, PlanMath.autoReviewLimit(dailyNew: 30)); p.dailyNew = 20
        p.dailyReview = 20; XCTAssertFalse(p.reviewAuto)
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
        XCTAssertTrue(p.reviewAuto); XCTAssertEqual(p.dailyReview, PlanMath.autoReviewLimit(dailyNew: 25)); XCTAssertEqual(p.dailyNew, 25); XCTAssertTrue(p.configured)
        let twenty = #"{"dailyNew":41,"dailyReview":20,"reviewEdited":false}"#
        XCTAssertEqual(try JSONDecoder().decode(StudyPlan.self, from: Data(twenty.utf8)).dailyReview, PlanMath.autoReviewLimit(dailyNew: 41))
        let custom = #"{"dailyReview":150}"#
        XCTAssertEqual(try JSONDecoder().decode(StudyPlan.self, from: Data(custom.utf8)).dailyReview, 150)
        var man = StudyPlan(); man.dailyReview = 20      // manual 20 survives a round trip
        let back = try JSONDecoder().decode(StudyPlan.self, from: JSONEncoder().encode(man))
        XCTAssertFalse(back.reviewAuto); XCTAssertEqual(back.dailyReview, 20)
        var auto = StudyPlan(); auto.dailyReview = 50; auto.reviewAuto = true
        XCTAssertEqual(try JSONDecoder().decode(StudyPlan.self, from: JSONEncoder().encode(auto)).dailyReview, PlanMath.autoReviewLimit(dailyNew: 20))
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

    func testReviewEstimate() {
        let per = PlanMath.reviewsPerNewWord(FSRS(desiredRetention: 0.9))
        XCTAssert(per > 3 && per < 15, "\(per)")
        XCTAssert(PlanMath.reviewsPerNewWord(FSRS(desiredRetention: 0.95)) > per)   // higher retention → more reviews
        XCTAssertEqual(PlanMath.estimatedDailyReviews(dailyNew: 0), 0)
        XCTAssertEqual(PlanMath.autoReviewLimit(dailyNew: 0), 10)
        let f = FSRS(desiredRetention: 0.9)
        let est = PlanMath.estimatedDailyReviews(dailyNew: 20, f), auto = PlanMath.autoReviewLimit(dailyNew: 20, f)
        XCTAssert(auto >= est && auto < est + 10 && auto % 10 == 0)
        XCTAssertEqual(PlanMath.dailyMinutes(new: 20, reviews: 150), 30)          // 10 + 20 min
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

final class StudiedWordsTests: XCTestCase {
    func tempURL() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("vocab.sqlite")
    }

    func testStudiedWordsStayOutOfWordbookUntilCollected() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = try WordStore(url: url)
        let w = try s.addStudied(word: "harbor", definition: "港口", dictionary: "ECDICT", source: WordSource(app: "词书·高考", title: "高考"))
        XCTAssertNil(w.bookID)
        let reviewed = try XCTUnwrap(s.review(id: w.id, rating: .good))
        // Collecting it later keeps the progress and puts it in 生词本.
        let c = try s.add(word: "harbor", definition: "", dictionary: "")
        XCTAssertEqual(c.id, w.id); XCTAssertNotNil(c.bookID)
        XCTAssertEqual(c.review.repetitions, reviewed.review.repetitions); XCTAssertEqual(c.review.stability, reviewed.review.stability)
        // A second addStudied does not pull it back out.
        XCTAssertNotNil(try s.addStudied(word: "harbor", definition: "", dictionary: "", source: nil).bookID)
    }

    func testV4MovesListWordsOutPreservingState() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ids: (list: Int64, mine: Int64, looked: Int64) = (0, 0, 0)
        var before: WordItem?
        do {
            let s = try WordStore(url: url)
            let l = try s.add(word: "magazine", definition: "杂志", dictionary: "ECDICT", source: WordSource(app: "词书·高考", title: "高考"))
            before = try s.review(id: l.id, rating: .good)
            let r = try s.add(word: "the", definition: "", dictionary: "ECDICT", source: WordSource(app: "词书·中考", title: "中考"))
            _ = try s.retire(id: r.id)
            let m = try s.add(word: "Atlantic", definition: "大西洋", dictionary: "x")
            let k = try s.add(word: "harbor", definition: "", dictionary: "x", context: "a harbor town", source: WordSource(app: "词书·高考", title: "高考"))
            ids = (l.id, m.id, k.id)
        }
        var db: OpaquePointer?
        sqlite3_open(url.path, &db); sqlite3_exec(db, "PRAGMA user_version = 3;", nil, nil, nil); sqlite3_close(db)
        let s = try WordStore(url: url)
        let m = try XCTUnwrap(s.migrationV4)
        XCTAssertEqual(m.moved, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(m.backup).path))
        let l = try XCTUnwrap(s.find(id: ids.list))
        XCTAssertNil(l.bookID)
        let b = try XCTUnwrap(before?.review)
        XCTAssertEqual(l.review.state, b.state); XCTAssertEqual(l.review.stability, b.stability)
        XCTAssertEqual(l.review.repetitions, b.repetitions)
        XCTAssertEqual(l.review.due.timeIntervalSince1970, b.due.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertTrue(Scheduler.isMastered(try XCTUnwrap(s.find(word: "the")).review))
        XCTAssertNil(try s.find(word: "the")?.bookID)
        XCTAssertNotNil(try s.find(id: ids.mine)?.bookID)
        XCTAssertNotNil(try s.find(id: ids.looked)?.bookID)     // has a context → the user collected it
        // Reopening doesn't migrate again.
        XCTAssertNil(try WordStore(url: url).migrationV4)
    }
}

final class FilenameSegmentationTests: XCTestCase {
    func w(_ t: String, _ i: Int) -> String? { WordUnderCursor.word(in: t, at: i)?.word }
    func testFilenamesSplitAtDotsAndUnderscores() {
        XCTAssertEqual(w("CONTRIBUTING.md", 3), "CONTRIBUTING")
        XCTAssertEqual(w("CONTRIBUTING.md", 14), "md")
        XCTAssertEqual(w(".env.example", 7), "example")
        XCTAssertEqual(w(".env.example", 2), "env")
        XCTAssertEqual(w("pyproject.toml", 2), "pyproject")
        XCTAssertEqual(w("pyproject.toml", 11), "toml")
        XCTAssertEqual(w(".gitignore", 4), "gitignore")
        XCTAssertEqual(w("AGENTS.md", 1), "AGENTS")
        XCTAssertEqual(w("snake_case_name", 7), "case")
        XCTAssertEqual(w("The harbor is calm.", 6), "harbor")      // prose unchanged
    }
}
