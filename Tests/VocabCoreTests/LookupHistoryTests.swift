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

    func testHeadwordStripsPinyinAndRejectsLabels() {
        XCTAssertEqual(LookupHistory.headword("你们  nǐmen"), "你们")
        XCTAssertEqual(LookupHistory.headword("你方 nǐfāng"), "你方")
        XCTAssertEqual(LookupHistory.headword("朝三暮四  zhāo sān mù sì"), "朝三暮四")
        XCTAssertEqual(LookupHistory.headword("apple pie"), "apple pie")
        XCTAssertNil(LookupHistory.headword("Food, dish-topic food"))
        var h = LookupHistory(); h.record("你们  nǐmen"); h.record("你们")
        XCTAssertEqual(h.words, ["你们"])
    }

    func testLoadCleansLegacyJunk() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "lh-\(UUID())"))
        d.set(["开发者", "朝三暮四  zhāosān-mùsì", "朝三暮四", "你们  nǐmen", "Food, dish-topic food", "apple"], forKey: LookupHistory.legacyKey)
        XCTAssertEqual(LookupHistory.load(d).words, ["开发者", "朝三暮四", "你们", "apple"])
        XCTAssertNotNil(d.data(forKey: LookupHistory.defaultsKey))
    }
}
