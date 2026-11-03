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
        // The study day rolls over at 02:00 (not midnight): 01:59 → 02:01 spans two study days.
        let before = cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 1, minute: 59))!
        let after = cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 2, minute: 1))!
        var log = DailyLog()
        let gap = after.timeIntervalSince(before)   // 120 s, under the 3-minute idle cap
        log.addStudy(gap, at: after, from: before, calendar: cal)

        let day1Secs = log.days[StudyDay.key(before, cal)]?.studySeconds ?? 0
        let day2Secs = log.days[StudyDay.key(after, cal)]?.studySeconds ?? 0
        XCTAssertNotEqual(StudyDay.key(before, cal), StudyDay.key(after, cal))
        XCTAssertEqual(day1Secs, 60, accuracy: 1, "Before 02:00 goes to the previous study day")
        XCTAssertEqual(day2Secs, 60, accuracy: 1, "After 02:00 goes to the new study day")
        XCTAssertEqual(day1Secs + day2Secs, gap, accuracy: 1, "Total time preserved")
    }

    func testMidnightIsNotADayBoundary() {
        let cal = Calendar.current
        let a = cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 23, minute: 59))!
        let b = cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 0, minute: 1))!
        var log = DailyLog()
        log.addStudy(120, at: b, from: a, calendar: cal)
        XCTAssertEqual(log.days[StudyDay.key(a, cal)]?.studySeconds ?? 0, 120, accuracy: 0.01)
    }

    func testIdleGapAcrossBoundaryNotCounted() {
        let cal = Calendar.current
        let a = cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 1, minute: 50))!
        let b = cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 2, minute: 10))!
        var log = DailyLog()
        log.addStudy(b.timeIntervalSince(a), at: b, from: a, calendar: cal)
        XCTAssertTrue(log.days.values.allSatisfy { $0.studySeconds == 0 }, "20 min idle is not study time")
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
    
    func testMasteredTogglePreservesCounts() throws {
        let store = try WordStore(url: nil)
        var item = try store.add(word: "toggle", definition: "切换", dictionary: "test")
        
        // Review it a few times
        item = try store.review(id: item.id, rating: .good)!
        item = try store.review(id: item.id, rating: .good)!
        let reps = item.review.repetitions
        
        // Retire
        item = try store.retire(id: item.id)!
        XCTAssertGreaterThan(item.review.repetitions, reps, "Retire increments reps")
        
        // Unretire preserves history
        item = try store.unretire(id: item.id)!
        XCTAssertGreaterThan(item.review.repetitions, 0, "History preserved after unretire")
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
    
    func testDictationThresholdsSameAsSpelling() {
        let len = 8
        let spell = RatingMap.thresholds(.spelling, length: len)
        let dict = RatingMap.thresholds(.dictation, length: len)
        XCTAssertEqual(spell.fast, dict.fast, "Dictation timing same as spelling")
        XCTAssertEqual(spell.slow, dict.slow, "Dictation timing same as spelling")
    }
}

final class FSRSVerificationTests: XCTestCase {
    func testSchedulerIsFSRS() {
        // Verify the scheduler uses FSRS (not SM-2)
        let fsrs = Scheduler.shared
        XCTAssertNotNil(fsrs as? FSRS, "Scheduler uses FSRS algorithm")
        XCTAssertEqual(fsrs.learningSteps, [60, 600], "Default FSRS learning steps")
        XCTAssertEqual(fsrs.desiredRetention, 0.9, "Default FSRS retention")
    }
    
    func testAutoRatingWiredToScheduler() {
        // Auto-rating produces valid ReviewRating values
        XCTAssertEqual(RatingMap.fromWrongCount(0), .good)
        XCTAssertEqual(RatingMap.fromWrongCount(1), .fuzzy)
        XCTAssertEqual(RatingMap.fromWrongCount(2), .forgot)
        
        // These ratings work with FSRS scheduler
        let now = Date()
        let state = ReviewState.new(now: now)
        _ = Scheduler.next(state, rating: .good, now: now)
        _ = Scheduler.next(state, rating: .fuzzy, now: now)
        _ = Scheduler.next(state, rating: .forgot, now: now)
    }
}

final class InlineDrillTests: XCTestCase {
    func testWrongAnswersMarkedForFinalPass() {
        var q = ReviewQueue(ids: [1, 2, 3])
        
        // Answer wrong
        q.answer(correct: false)
        XCTAssertTrue(q.missedWords.contains(1), "Wrong answer marked for final pass")
        XCTAssertEqual(q.wrong[1], 1, "Wrong count tracked")
        
        // Answer correctly later in main pass
        XCTAssertEqual(q.current, 2, "Wrong word requeued")
        q.answer(correct: true)
        q.answer(correct: true)
        q.answer(correct: true)  // word 1 again

        // Still owed a final re-test (see FinalPassTests); cleared only when the final pass gets it right.
        XCTAssertTrue(q.missedWords.contains(1))
        q.startFinalPass()
        q.answer(correct: true)
        XCTAssertFalse(q.missedWords.contains(1), "Cleared when answered correctly in the final pass")
        XCTAssertTrue(q.finished)
    }
}

final class FinalPassTests: XCTestCase {
    func testMissedWordsRetested() {
        var q = ReviewQueue(ids: [1, 2, 3])
        
        // Answer: correct, wrong, correct
        q.answer(correct: true)   // 1 done
        q.answer(correct: false)  // 2 wrong, requeued
        q.answer(correct: true)   // 3 done
        
        XCTAssertTrue(q.missedWords.contains(2), "Wrong word marked for final pass")
        XCTAssertEqual(q.pending, [2], "Wrong word still pending")
        
        // Answer it again correctly
        q.answer(correct: true)   // 2 done
        XCTAssertTrue(q.pending.isEmpty, "Main queue done")
        XCTAssertFalse(q.missedWords.isEmpty, "Missed word still tracked")
        
        // Start final pass
        q.startFinalPass()
        XCTAssertTrue(q.inFinalPass, "Final pass started")
        XCTAssertEqual(q.pending.count, 1, "Missed word re-queued")
        XCTAssertFalse(q.finished, "Not finished until final pass done")
        
        // Answer in final pass
        q.answer(correct: true)
        XCTAssertTrue(q.finished, "Finished after final pass")
    }
}

final class PassagePasteTests: XCTestCase {
    func testPassageDetection() {
        XCTAssertFalse(TypeToSearch.isPassage("adjust"))
        XCTAssertFalse(TypeToSearch.isPassage("look up to"))
        XCTAssertFalse(TypeToSearch.isPassage("调整"))
        XCTAssertTrue(TypeToSearch.isPassage("The quick brown fox jumps over the lazy dog."))
        XCTAssertTrue(TypeToSearch.isPassage("却说天下大势，分久必合，合久必分。"), "Chinese has no spaces")
        XCTAssertTrue(TypeToSearch.isPassage("first line\nsecond line"))
    }
}
