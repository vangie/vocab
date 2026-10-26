import XCTest
@testable import VocabCore

final class TypeToSearchTests: XCTestCase {
    private func r(_ c: String?, _ k: UInt16 = 0, cmd: Bool = false, ctl: Bool = false, lookup: Bool = true, focused: Bool = false) -> Bool {
        TypeToSearch.shouldRedirect(characters: c, keyCode: k, command: cmd, control: ctl, lookupMode: lookup, textFocused: focused)
    }
    func testPrintableRedirects() {
        XCTAssertTrue(r("a", 0)); XCTAssertTrue(r("Z", 6)); XCTAssertTrue(r("7", 26)); XCTAssertTrue(r("词", 0)); XCTAssertTrue(r("é", 14))
    }
    func testReservedAndModifiers() {
        XCTAssertFalse(r("a", 0, cmd: true)); XCTAssertFalse(r("a", 0, ctl: true))
        XCTAssertFalse(r(" ", 49)); XCTAssertFalse(r("\t", 48)); XCTAssertFalse(r("\u{1b}", 53))
        XCTAssertFalse(r("\u{F700}", 126)); XCTAssertFalse(r("\r", 36))
    }
    func testOnlyInLookupWithoutFocus() {
        XCTAssertFalse(r("1", 18, lookup: false)); XCTAssertFalse(r("a", 0, focused: true))
    }

    func testPasteQuery() {
        XCTAssertEqual(TypeToSearch.pasteQuery("  serendipity \n"), "serendipity")
        XCTAssertEqual(TypeToSearch.pasteQuery("take\n  off\tnow"), "take off now")
        XCTAssertNil(TypeToSearch.pasteQuery(" \n\t "))
        XCTAssertNil(TypeToSearch.pasteQuery(nil))
        XCTAssertEqual(TypeToSearch.pasteQuery(String(repeating: "a", count: 300))?.count, 100)
    }
}
