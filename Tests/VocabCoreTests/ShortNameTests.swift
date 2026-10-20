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

final class WikipediaHTMLTests: XCTestCase {
    func testWikipediaEntriesAreWellFormedXHTML() {
        let d = DictionaryInfo(id: "com.apple.dictionary.Wikipedia", name: "维基百科", shortName: "维基百科", bundleURL: nil)
        let found = WikipediaClient.entry(.found(title: "哈哈 & <x>", html: "", text: "t"), dictionary: d, term: "哈哈")
        XCTAssertNotNil(found)
        let failed = WikipediaClient.entry(.failed, dictionary: d, term: "哈哈")!
        XCTAssertNil(WikipediaClient.entry(.notFound, dictionary: d, term: "哈哈"))
        let status = WikipediaClient.statusEntry("正在查询维基百科…", dictionary: d, term: "哈哈")
        let page = WikipediaClient.page(title: "A&B <c>", description: "x \"y\"", extract: "1 < 2 & 3", url: "https://zh.wikipedia.org/wiki/%E5%93%88?a=1&b=2")
        XCTAssertTrue(EntryHTML.isWellFormedXML(EntryHTML.prepare(page, resourceDirectory: nil)))
        for e in [failed, status] {
            XCTAssertTrue(EntryHTML.isWellFormedXML(EntryHTML.prepare(e.html, resourceDirectory: nil)), e.html)
        }
    }
}
