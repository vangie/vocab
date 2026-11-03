import XCTest
@testable import VocabCore

final class AutoRatingTests: XCTestCase {
    func testAutoRatingFromWrongCount() {
        XCTAssertEqual(RatingMap.fromWrongCount(0), .good, "First try correct = Good")
        XCTAssertEqual(RatingMap.fromWrongCount(1), .fuzzy, "One miss = Hard")
        XCTAssertEqual(RatingMap.fromWrongCount(2), .forgot, "2+ misses = Again")
        XCTAssertEqual(RatingMap.fromWrongCount(5), .forgot, "Many misses = Again")
    }

    func testDictationThresholdsMatchSpelling() {
        let spelling = RatingMap.thresholds(.spelling, length: 8)
        let dictation = RatingMap.thresholds(.dictation, length: 8)
        XCTAssertEqual(spelling.fast, dictation.fast, "Dictation uses same thresholds as spelling")
        XCTAssertEqual(spelling.slow, dictation.slow, "Dictation uses same thresholds as spelling")
    }
}

final class FlowSeparationTests: XCTestCase {
    func testNewWordsGetRecognitionFirst() {
        let weights = QuestionPicker.weights(.new)
        XCTAssertTrue(weights.keys.contains(.wordToMeaning), "New: see word → choose meaning")
        XCTAssertTrue(weights.keys.contains(.meaningToWord), "New: see meaning → choose word")
        XCTAssertFalse(weights.keys.contains(.recall), "New: no self-graded recall")
    }

    func testMatureWordsTestRecall() {
        let weights = QuestionPicker.weights(.mature)
        XCTAssertTrue(weights.keys.contains(.dictation), "Mature: dictation for recall testing")
        XCTAssertTrue(weights.keys.contains(.recall), "Mature: self-graded recall allowed")
    }

    func testLearningWordsGetMixedPractice() {
        let weights = QuestionPicker.weights(.learning)
        XCTAssertTrue(weights.keys.contains(.spelling), "Learning: spelling practice")
        XCTAssertTrue(weights.keys.contains(.dictation), "Learning: dictation introduced")
    }
}

final class DistractorSimilarityTests: XCTestCase {
    func testChineseGlossSimilarityWithCharacterOverlap() {
        let sim1 = Distractors.chineseGlossSimilarity("调整", "调节")
        XCTAssertGreaterThan(sim1, 0.3, "Similar meanings share characters: 调整 vs 调节")

        let sim2 = Distractors.chineseGlossSimilarity("收养", "适应")
        XCTAssertLessThan(sim2, 0.3, "Different meanings have low overlap")
    }

    func testChineseGlossSimilarityWithBigrams() {
        let sim = Distractors.chineseGlossSimilarity("调整…以适用", "调整，调节")
        XCTAssertGreaterThan(sim, 0.3, "Shared bigrams detected")
    }

    func testKeepRejectsTooSimilarChinese() {
        let target = Gloss(chinese: "调整", english: "adjust")
        let tooSimilar = Gloss(chinese: "调节，调整", english: "regulate")
        let ok = Gloss(chinese: "收养", english: "adopt")

        XCTAssertFalse(Distractors.keep(target: "adjust", candidate: "regulate", targetGloss: target,
                                         candidateGloss: tooSimilar), "Reject very similar Chinese")
        XCTAssertTrue(Distractors.keep(target: "adjust", candidate: "adopt", targetGloss: target,
                                        candidateGloss: ok), "Keep sufficiently different")
    }
}

final class StudyTimerTests: XCTestCase {
    func testIdleGapsPauseTimer() {
        var log = DailyLog()
        let now = Date()

        // Active study: 30s gap counted
        log.addStudy(30, at: now)
        XCTAssertGreaterThan(log.today(now).studySeconds, 0)

        // Idle gap: 4 min (240s) not counted
        var log2 = DailyLog()
        log2.addStudy(240, at: now)
        XCTAssertEqual(log2.today(now).studySeconds, 0, "Long idle gap not counted")
    }

    func testStudyTimeSplitsAt2AM() {
        let cal = Calendar.current
        let day1 = cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 23, minute: 30))!
        let day2 = cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 0, minute: 10))!

        var log = DailyLog()
        log.addStudy(60, at: day1)
        log.addStudy(60, at: day2)

        // Both days get their time (2am boundary respected)
        XCTAssertGreaterThan(log.days[DailyLog.key(day1, cal)]?.studySeconds ?? 0, 0, "Day 1 has study time")
        XCTAssertGreaterThan(log.days[DailyLog.key(day2, cal)]?.studySeconds ?? 0, 0, "Day 2 has study time")
    }
}

final class MasteredStateTests: XCTestCase {
    func testRetireAndUnretire() throws {
        let store = try WordStore(url: nil)
        var item = try store.add(word: "test", definition: "测试", dictionary: "test")
        XCTAssertFalse(Scheduler.isMastered(item.review), "New word not mastered")

        // Retire
        item = try store.retire(id: item.id)!
        XCTAssertTrue(Scheduler.isMastered(item.review), "Retired word is mastered")

        // Unretire
        item = try store.unretire(id: item.id)!
        XCTAssertFalse(Scheduler.isMastered(item.review), "Unretired word back in rotation")
        XCTAssertLessThan(item.review.intervalDays, 2, "Unretired with short interval")
    }
}

final class DictationTests: XCTestCase {
    func testDictationRequiresAudio() {
        var m = WordMaterials()
        m.gloss = Gloss(chinese: "测试")
        XCTAssertFalse(m.available.contains(.dictation), "No audio = no dictation")

        m.audio = URL(fileURLWithPath: "/tmp/test.mp3")
        XCTAssertTrue(m.available.contains(.dictation), "Audio present = dictation available")
    }

    func testDictationInWeights() {
        let mature = QuestionPicker.weights(.mature)
        XCTAssertTrue(mature.keys.contains(.dictation), "Dictation in mature weights")
        XCTAssertGreaterThan(mature[.dictation] ?? 0, 0, "Dictation has positive weight")
    }
}
