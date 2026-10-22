import XCTest
@testable import VocabCore

final class StudyDayTests: XCTestCase {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }
    func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))! }

    func testRolloverAt2am() {
        XCTAssertEqual(StudyDay.key(at(23, 1, 59), cal), "2026-10-22")
        XCTAssertEqual(StudyDay.key(at(23, 2, 0), cal), "2026-10-23")
        XCTAssertTrue(StudyDay.same(at(22, 9), at(23, 1, 30), cal))
    }
    func testGoalFixedAtStartOfDay() {
        var log = DailyLog()
        log.snapshot(at(22, 9), newLeft: 20, reviewsLeft: 5, newDone: 0, reviewsDone: 0, newCap: 20, calendar: cal)
        log.snapshot(at(22, 10), newLeft: 10, reviewsLeft: 0, newDone: 10, reviewsDone: 5, newCap: 20, calendar: cal)
        XCTAssertEqual(log.today(at(22, 10), calendar: cal).newQuota, 20)
        log.snapshot(at(22, 11), newLeft: 0, reviewsLeft: 0, newDone: 20, reviewsDone: 5, newCap: 20, calendar: cal)
        XCTAssertTrue(log.today(at(22, 11), calendar: cal).completed)
        // An extra group: done grows, the goal doesn't.
        log.snapshot(at(22, 12), newLeft: 0, reviewsLeft: 0, newDone: 35, reviewsDone: 5, newCap: 20, calendar: cal)
        let r = log.today(at(22, 12), calendar: cal)
        XCTAssertEqual(r.newQuota, 20); XCTAssertEqual(r.newDone, 35)
        // Activity at 1 am belongs to the 22nd.
        log.snapshot(at(23, 1), newLeft: 0, reviewsLeft: 0, newDone: 36, reviewsDone: 5, newCap: 20, calendar: cal)
        XCTAssertEqual(log.days["2026-10-22"]?.newDone, 36); XCTAssertNil(log.days["2026-10-23"])
    }
    func testPlanEditRefixesGoal() {
        var log = DailyLog()
        log.snapshot(at(22, 9), newLeft: 20, reviewsLeft: 0, newDone: 0, reviewsDone: 0, newCap: 20, calendar: cal)
        log.snapshot(at(22, 10), newLeft: 25, reviewsLeft: 0, newDone: 5, reviewsDone: 0, newCap: 30, calendar: cal)
        XCTAssertEqual(log.today(at(22, 10), calendar: cal).newQuota, 30)
    }
    func testStreakAcrossRollover() {
        var log = DailyLog()
        log.snapshot(at(21, 23), newLeft: 0, reviewsLeft: 0, newDone: 5, reviewsDone: 0, newCap: 5, calendar: cal)
        log.days["2026-10-21"]?.newQuota = 5; log.days["2026-10-21"]?.completed = true
        XCTAssertEqual(log.streak(at(22, 1, 30), calendar: cal), 1)
    }
}
