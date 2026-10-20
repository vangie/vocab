import XCTest
@testable import VocabCore

final class ShortNameTests: XCTestCase {
    func testShortNamesDefaultToOriginal() {
        let suite = "vocab-test-\(UUID())"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let old = DictionaryNames.store; DictionaryNames.store = d; defer { DictionaryNames.store = old }
        let info = DictionaryInfo(id: "x.y", name: "牛津英汉汉英词典", shortName: "牛津", bundleURL: nil)
        XCTAssertEqual(info.displayName, "牛津英汉汉英词典")      // not the bundle's short name: no pre-fill
        DictionaryNames.set("  牛津 ", for: "x.y"); XCTAssertEqual(info.displayName, "牛津")
        DictionaryNames.set("", for: "x.y"); XCTAssertEqual(info.displayName, "牛津英汉汉英词典")
        XCTAssertNil(DictionaryNames.custom("x.y"))
    }

    func testPageHasSectionAnchorsAndSpy() {
        let p = EntryHTML.page(sections: [.init(title: "A", frameURLs: []), .init(title: "B", frameURLs: [])], showTitles: true)
        XCTAssertTrue(p.contains("id=\"vsec-0\"")); XCTAssertTrue(p.contains("id=\"vsec-1\""))
        XCTAssertTrue(p.contains("vocabSection")); XCTAssertTrue(p.contains("vocabScrollTo"))
    }
}
