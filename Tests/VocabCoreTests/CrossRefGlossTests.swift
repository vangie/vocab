import XCTest
@testable import VocabCore

final class CrossRefGlossTests: XCTestCase {
    func testTidy() {
        XCTAssertEqual(GlossExtractor.tidy("/ labour 的美式拼法"), "labour 的美式拼法")
        XCTAssertEqual(GlossExtractor.tidy("影响；"), "影响")
        XCTAssertEqual(GlossExtractor.tidy(", 劳动 /"), "劳动")
        XCTAssertNil(GlossExtractor.tidy(" / "))
    }

    func testDetect() {
        XCTAssertEqual(GlossExtractor.crossReference("/ labour 的美式拼法")?.base, "labour")
        XCTAssertEqual(GlossExtractor.crossReference("lie¹的过去式")?.base, "lie")
        XCTAssertEqual(GlossExtractor.crossReference("the past tense of lie¹")?.base, "lie")
        XCTAssertEqual(GlossExtractor.crossReference("= labour")?.base, "labour")
        XCTAssertEqual(GlossExtractor.crossReference("see labour")?.base, "labour")
        XCTAssertEqual(GlossExtractor.crossReference("variant of colour")?.base, "colour")
        XCTAssertNil(GlossExtractor.crossReference("劳动；工作"))
        XCTAssertNil(GlossExtractor.crossReference("to put something down carefully"))
        XCTAssertNil(GlossExtractor.crossReference("see something happen"))   // not just a pointer
    }

    private let raw: (String) -> Gloss = { w in
        switch w {
        case "labor": Gloss(chinese: "/ labour 的美式拼法", english: "the American spelling of labour")
        case "labour": Gloss(chinese: "劳动", english: "work, especially physical work")
        case "lay": Gloss(chinese: "lie¹的过去式", english: "the past tense of lie¹")
        case "lie": Gloss(chinese: "躺；平卧", english: "to be in a position in which your body is flat")
        case "orphan": Gloss(chinese: "/ ghost 的美式拼法")
        default: Gloss()
        }
    }

    func testFollowsToBaseWithFeedbackNote() {
        let g = QuestionFactory.resolve("labor", raw: raw)
        XCTAssertEqual(g.chinese, "劳动"); XCTAssertEqual(g.short, "劳动")
        XCTAssertEqual(g.english, "work, especially physical work")
        XCTAssertEqual(g.note, "labour 的美式拼法")
        let l = QuestionFactory.resolve("lay", raw: raw)
        XCTAssertEqual(l.chinese, "躺；平卧"); XCTAssertEqual(l.note, "lie¹的过去式")
    }

    func testUnresolvedLeavesNoMeaning() {
        let g = QuestionFactory.resolve("orphan", raw: raw)
        XCTAssertNil(g.chinese); XCTAssertTrue(g.isEmpty)
        var m = WordMaterials(); m.gloss = g
        XCTAssertFalse(m.available.contains(.wordToMeaning)); XCTAssertFalse(m.available.contains(.meaningToWord))
    }
}
