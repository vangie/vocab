import XCTest
@testable import VocabCore

/// The active click tap must never outlive Accessibility trust (a stale active tap froze every click).
final class ClickSuppressorTrustTests: XCTestCase {
    func testDisabledTapReenabledOnlyWhileTrusted() {
        XCTAssertEqual(ClickSuppressor.onDisabled(trusted: true), .reenable)
        XCTAssertEqual(ClickSuppressor.onDisabled(trusted: false), .teardown)
    }
    func testNoTapWithoutTrust() {
        let s = ClickSuppressor()
        s.isTrusted = { false }
        XCTAssertFalse(s.sync())          // not wanted
        XCTAssertFalse(s.isRunning)
    }
}
