import XCTest
@testable import VocabCore

final class LookupHistoryTests: XCTestCase {
    func testDedupeOrderCapDelete() {
        var h = LookupHistory(limit: 3)
        let t = Date(timeIntervalSince1970: 1_000)
        h.record("apple", at: t); h.record("Banana", at: t + 1); h.record("APPLE", at: t + 2); h.record("  ", at: t + 3)
        XCTAssertEqual(h.words, ["APPLE", "Banana"])
        XCTAssertEqual(h.entries.first?.date, t + 2)
        h.record("c"); h.record("d")
        XCTAssertEqual(h.words, ["d", "c", "APPLE"])               // capped at 3
        h.remove("apple"); XCTAssertEqual(h.words, ["d", "c"])
        h.clear(); XCTAssertTrue(h.entries.isEmpty)
    }

    func testPersistAndMigrateLegacy() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "lh-\(UUID())"))
        d.set(["开", "word"], forKey: LookupHistory.legacyKey)
        var h = LookupHistory.load(d)
        XCTAssertEqual(h.words, ["开", "word"])
        h.record("new"); h.save(d)
        XCTAssertEqual(LookupHistory.load(d).words, ["new", "开", "word"])
    }
}
