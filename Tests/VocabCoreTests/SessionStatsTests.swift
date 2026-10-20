import XCTest
@testable import VocabCore

/// 斩 right after answering replaces the answer: stats return to the pre-answer tallies and the
/// card leaves the queue (including a wrong answer's relearning requeue).
final class SessionStatsTests: XCTestCase {
    func testRetireAfterAnswerUndoesTally() {
        var s = SessionStats()
        s.record(.good, correct: true, type: .spelling)
        let before = (s.answered, s.correct, s.wrong, s.ratings, s.byType[.spelling]?.total)
        s.record(.forgot, correct: false, type: .wordToMeaning)
        s.unrecord(.forgot, correct: false, type: .wordToMeaning)
        XCTAssertEqual(s.answered, before.0); XCTAssertEqual(s.correct, before.1); XCTAssertEqual(s.wrong, before.2)
        XCTAssertEqual(s.ratings, before.3); XCTAssertEqual(s.byType[.spelling]?.total, before.4)
        XCTAssertNil(s.byType[.wordToMeaning])
    }

    func testRetireAfterWrongAnswerDropsRequeue() {
        var q = ReviewQueue(ids: [1, 2, 3])
        q.answer(correct: false)              // card 1 wrong → requeued for relearning
        q.dropCurrentRequeue(1)               // 斩 in the answered state
        XCTAssertFalse(q.pending.contains(1))
        XCTAssertEqual(q.current, 2)
    }
}
