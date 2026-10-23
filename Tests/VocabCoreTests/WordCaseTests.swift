import XCTest
@testable import VocabCore

final class WordCaseTests: XCTestCase {
    func testCanonical() {
        XCTAssertEqual(WordCase.canonical("Steer", headwords: ["steer", "steer1"]), "steer")
        XCTAssertEqual(WordCase.canonical("atlantic", headwords: ["At·lan·tic2", "Atlantic"]), "Atlantic")
        XCTAssertEqual(WordCase.canonical("Polish", headwords: ["Polish", "polish"]), "polish")
        XCTAssertEqual(WordCase.canonical("Zyxw", headwords: ["zebra"]), "Zyxw")
    }
    func testCaseInsensitiveDedupe() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wc-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let s = try WordStore(url: url)
        _ = try s.add(word: "steer", definition: "a", dictionary: "x")
        _ = try s.add(word: "Steer", definition: "b", dictionary: "x")
        XCTAssertEqual(try s.all().count, 1)
    }
    func testOALDSummary() {
        let html = #"<h1 class="o-headword">steer</h1><span class="o-pron-geo">BrE</span><span class="ph" dialect="BrE">stɪə(r)</span><span class="o-pron-geo">NAmE</span><span class="ph" dialect="AmE">stɪr</span><span class="o-def-eng"><span class="o-tag o-eng"> to control the direction</span></span><span class="o-def-simp"><span class="o-tag">驾驶</span></span>"#
        XCTAssertEqual(DictionaryEntry.makeSummary(html: html, plainText: "steerBrEstɪə(r)NAmEstɪr", headword: "steer"), "/stɪr/ 驾驶 · to control the direction")
        XCTAssertEqual(DictionaryEntry.cleanPlainText("steerBrEstɪə(r)NAmEstɪr verb", headword: "steer"), "BrE stɪə(r) NAmE stɪr verb")
    }
}
