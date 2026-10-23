import XCTest
@testable import VocabCore

final class NavStackTests: XCTestCase {
    func testBackForwardTruncate() {
        var n = NavStack<String>()
        n.visit("quiz"); n.visit("dict:steer"); n.visit("dict:steer")
        XCTAssertEqual(n.items, ["quiz", "dict:steer"])
        XCTAssertEqual(n.back(), "quiz"); XCTAssertFalse(n.canGoBack); XCTAssertTrue(n.canGoForward)
        XCTAssertEqual(n.forward(), "dict:steer"); XCTAssertNil(n.forward())
        _ = n.back(); n.visit("words")
        XCTAssertEqual(n.items, ["quiz", "words"]); XCTAssertFalse(n.canGoForward)
    }
}
