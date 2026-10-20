import XCTest
@testable import VocabCore

final class SuperscriptGlossTests: XCTestCase {
    func testSupDigitsBecomeUnicodeSuperscripts() {
        XCTAssertEqual(GlossExtractor.text("the past tense of lie<sup>1</sup>"), "the past tense of lie¹")
        XCTAssertEqual(GlossExtractor.text("lie<sup class=\"hom\"><span>2</span></sup>的过去式"), "lie²的过去式")
        XCTAssertEqual(GlossExtractor.text("x<SUP> 12 </SUP>"), "x¹²")
        XCTAssertEqual(GlossExtractor.text("m<sup>th</sup>"), "mth")   // non-digits unchanged
    }

    func testGlossExtractionKeepsHomographNumber() {
        let html = "<span class=\"DEF\"><span class=\"cn_txt\">lie<sup>1</sup>的过去式</span></span>"
        XCTAssertEqual(GlossExtractor.english(fromHTML: "<span class=\"DEF\">the past tense of <a>lie<sup>1</sup></a></span>"),
                       "the past tense of lie¹")
        XCTAssertEqual(GlossExtractor.chinese(fromHTML: html), "lie¹的过去式")
    }
}
