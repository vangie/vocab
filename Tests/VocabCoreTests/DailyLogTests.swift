import XCTest
@testable import VocabCore

final class DailyLogTests: XCTestCase {
    let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }()
    func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: Date(timeIntervalSince1970: 1_800_000_000))! }

    func testSnapshotAndCompletion() {
        var log = DailyLog()
        log.snapshot(day(0), newLeft: 20, reviewsLeft: 30, newDone: 0, reviewsDone: 0, calendar: cal)
        var t = log.today(day(0), calendar: cal)
        XCTAssertEqual(t.newQuota, 20); XCTAssertEqual(t.reviewTarget, 30); XCTAssertFalse(t.completed)
        log.snapshot(day(0), newLeft: 5, reviewsLeft: 0, newDone: 15, reviewsDone: 30, calendar: cal)
        t = log.today(day(0), calendar: cal)
        XCTAssertEqual(t.newQuota, 20); XCTAssertFalse(t.completed)
        log.snapshot(day(0), newLeft: 0, reviewsLeft: 0, newDone: 20, reviewsDone: 30, calendar: cal)
        XCTAssertTrue(log.today(day(0), calendar: cal).completed)
        // Nothing scheduled → rest day, not completed.
        log.snapshot(day(1), newLeft: 0, reviewsLeft: 0, newDone: 0, reviewsDone: 0, calendar: cal)
        XCTAssertFalse(log.today(day(1), calendar: cal).completed); XCTAssertTrue(log.today(day(1), calendar: cal).isRest)
    }

    func testStreak() {
        var log = DailyLog()
        func done(_ d: Int) { log.snapshot(day(d), newLeft: 0, reviewsLeft: 0, newDone: 10, reviewsDone: 5, calendar: cal) }
        done(-4); done(-3); done(-1)
        log.snapshot(day(-2), newLeft: 0, reviewsLeft: 0, newDone: 0, reviewsDone: 0, calendar: cal)   // rest day
        // Today not started yet: streak survives.
        XCTAssertEqual(log.streak(day(0), calendar: cal), 3)
        // Today in progress: still 3.
        log.snapshot(day(0), newLeft: 10, reviewsLeft: 2, newDone: 0, reviewsDone: 0, calendar: cal)
        XCTAssertEqual(log.streak(day(0), calendar: cal), 3)
        done(0)
        XCTAssertEqual(log.streak(day(0), calendar: cal), 4)
        // A missed day (no record) ends it.
        XCTAssertEqual(log.streak(day(2), calendar: cal), 0)
        // An unfinished day ends it.
        log.snapshot(day(1), newLeft: 3, reviewsLeft: 0, newDone: 7, reviewsDone: 0, calendar: cal)
        XCTAssertEqual(log.streak(day(2), calendar: cal), 0)
        let back = try! JSONDecoder().decode(DailyLog.self, from: JSONEncoder().encode(log))
        XCTAssertEqual(back, log)
    }

    func testPlanProgress() {
        func item(_ w: String, _ st: CardState, stab: Double? = nil, ivl: Double = 0) -> WordItem {
            var r = ReviewState(state: st, due: Date()); r.stability = stab; r.intervalDays = ivl
            return WordItem(id: 1, word: w, definition: "", dictionary: "", context: nil, added: Date(), review: r)
        }
        let p = PlanProgress.compute(words: ["a", "b", "c", "d", "e"], skipped: ["e"],
                                     items: [item("A", .review, stab: 30), item("b", .learning, stab: 2),
                                             item("c", .new), item("z", .review, stab: 50),
                                             item("d", .new, ivl: Scheduler.masteredInterval)])
        XCTAssertEqual(p, PlanProgress(total: 4, learned: 3, mastered: 2))
        XCTAssertEqual(p.fraction, 0.75)
    }
}

final class DailyLogTargetTests: XCTestCase {
    /// Regression (今日复习 13/14 while done): the review target follows what is still queueable.
    func testReviewTargetShrinksWhenCardLeavesQueue() {
        var log = DailyLog(); let now = Date()
        log.snapshot(now, newLeft: 0, reviewsLeft: 14, newDone: 0, reviewsDone: 0)
        log.snapshot(now, newLeft: 0, reviewsLeft: 1, newDone: 0, reviewsDone: 13)
        log.snapshot(now, newLeft: 0, reviewsLeft: 0, newDone: 0, reviewsDone: 13)   // last card 斩/filtered
        let t = log.today(now)
        XCTAssertEqual(t.reviewsDone, 13); XCTAssertEqual(t.reviewTarget, 13); XCTAssertTrue(t.completed)
    }

    func testStudyTimeSkipsIdleGapsAndOldRecordsDecode() throws {
        var log = DailyLog(); let now = Date()
        log.addStudy(20, at: now); log.addStudy(40, at: now); log.addStudy(300, at: now)   // 300 s = idle
        XCTAssertEqual(log.today(now).studySeconds, 60)
        let old = #"{"days":{"2026-01-01":{"newQuota":1,"newDone":1,"reviewTarget":0,"reviewsDone":0,"completed":true}}}"#
        let d = try JSONDecoder().decode(DailyLog.self, from: Data(old.utf8))
        XCTAssertEqual(d.days["2026-01-01"]?.studySeconds, 0); XCTAssertEqual(d.days["2026-01-01"]?.newDone, 1)
    }
}
