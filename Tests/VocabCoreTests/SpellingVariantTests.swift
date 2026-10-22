import XCTest
@testable import VocabCore

final class SpellingVariantTests: XCTestCase {
    func testVariants() {
        for (a, b) in [("realise", "realize"), ("realisation", "realization"), ("analyse", "analyze"), ("colour", "color"),
                       ("centre", "center"), ("catalogue", "catalog"), ("travelled", "traveled"), ("organising", "organizing")] {
            XCTAssertTrue(Distractors.isSpellingVariant(a, b), "\(a)/\(b)")
        }
        for (a, b) in [("realise", "really"), ("affect", "effect"), ("adapt", "adopt"), ("four", "for")] {
            XCTAssertFalse(Distractors.isSpellingVariant(a, b), "\(a)/\(b)")
        }
    }
    func testRankExcludesVariant() {
        let r = Distractors.rank(target: "realise", candidates: ["realize", "realism", "really"]).map(\.word)
        XCTAssertFalse(r.contains("realize"))
    }
    func testKeepDropsAlsoForm() {
        XCTAssertFalse(Distractors.keep(target: "realise", candidate: "realize", targetGloss: Gloss(chinese: "意识到"), candidateGloss: Gloss(chinese: "实现")))
        XCTAssertFalse(Distractors.keep(target: "grey", candidate: "gray", targetGloss: Gloss(chinese: "灰色"), candidateGloss: Gloss(english: "also grey: a colour")))
    }
    func testVariantChoiceCountsCorrect() {
        var q = ReviewQuestion(type: .meaningToWord, itemID: 0, word: "realise", gloss: Gloss(chinese: "意识到"))
        q.options = ["realize", "realise", "really"]; q.optionWords = q.options; q.correctIndex = 1
        XCTAssertTrue(q.isCorrectChoice(0)); XCTAssertTrue(q.isCorrectChoice(1)); XCTAssertFalse(q.isCorrectChoice(2))
    }
}
