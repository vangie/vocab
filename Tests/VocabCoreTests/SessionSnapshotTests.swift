import XCTest
@testable import VocabCore

final class SessionSnapshotTests: XCTestCase {
    private func snap(date: Date = Date()) -> SessionSnapshot {
        var q = ReviewQueue(ids: [5, -1, 7, 9])
        q.answer(correct: false)   // 5 goes back as a retry-later card
        q.retire()                 // -1 斩
        var st = SessionStats(); st.record(.good, correct: true, type: .wordToMeaning); st.retired = 1
        return SessionSnapshot(date: date, queue: q, stats: st,
                               virtuals: [.init(id: -1, word: "abate", definition: "减弱", list: .cet6)],
                               realID: [-1: 42], newSource: [-1: .cet6], quickCheck: [-1], answeredOnce: [5], firstDone: [-1])
    }

    func testRoundTripKeepsQueueAndStats() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "ss-\(UUID())"))
        let s = snap(); s.save(d)
        let l = try XCTUnwrap(SessionSnapshot.load(d))
        XCTAssertEqual(l.queue, s.queue)
        XCTAssertEqual(l.queue.pending, [7, 9, 5])
        XCTAssertEqual(l.queue.done, [-1])
        XCTAssertEqual(l.queue.wrong[5], 1)
        XCTAssertEqual(l.stats.answered, 1); XCTAssertEqual(l.stats.retired, 1)
        XCTAssertEqual(l.stats.ratings[.good], 1)
        XCTAssertEqual(l.stats.byType[.wordToMeaning]?.right, 1)
        XCTAssertEqual(l.virtuals, s.virtuals); XCTAssertEqual(l.realID, [-1: 42]); XCTAssertEqual(l.newSource, [-1: .cet6])
        SessionSnapshot.clear(d); XCTAssertNil(SessionSnapshot.load(d))
    }

    func testResumableOnlySameDayAndUnfinished() {
        let now = Date()
        XCTAssertTrue(snap(date: now).resumable(now: now))
        XCTAssertFalse(snap(date: now.addingTimeInterval(-86400 * 2)).resumable(now: now))
        var done = snap(date: now)
        while !done.queue.finished { done.queue.retire() }
        XCTAssertFalse(done.resumable(now: now))
    }
}
