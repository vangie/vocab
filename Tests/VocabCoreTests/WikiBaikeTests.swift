import XCTest
@testable import VocabCore

final class WikiBaikeTests: XCTestCase {
    func testLanguageDefaultsAndOrder() {
        let d = UserDefaults(suiteName: "vocab-test-wiki-\(UUID())")!
        XCTAssertEqual(WikipediaClient.languages(d), ["zh", "en"])
        WikipediaClient.setLanguages(["en", "ja", "xx"], d)
        XCTAssertEqual(WikipediaClient.languages(d), ["en", "ja"])
        WikipediaClient.setLanguages([], d)
        XCTAssertEqual(WikipediaClient.languages(d), ["zh", "en"])
        XCTAssertEqual(WikipediaClient.order(preferred: "en", ticked: ["zh", "en"]), ["en", "zh"])
        XCTAssertEqual(WikipediaClient.order(preferred: "fr", ticked: ["zh", "en"]), ["zh", "en"])
        XCTAssertEqual(WikipediaClient.order(preferred: nil, ticked: ["zh", "en"]), ["zh", "en"])
    }

    func testParseLanglinks() {
        let ok = #"{"query":{"pages":[{"title":"Apple","langlinks":[{"lang":"zh","title":"苹果"},{"lang":"ja","title":"リンゴ"}]}]}}"#
        let r = WikipediaClient.parseLanglinks(Data(ok.utf8))
        XCTAssertEqual(r?.title, "Apple")
        XCTAssertEqual(r?.links["zh"], "苹果")
        XCTAssertNil(WikipediaClient.parseLanglinks(Data(#"{"query":{"pages":[{"title":"Qzx","missing":true}]}}"#.utf8)))
    }

    func testBaikeParse() {
        let json = #"""
        {"title":"苹果公司","desc":"上市科技公司","abstract":"苹果公司（Apple Inc.）是<b>美国</b>公司","hasOther":1,
         "card":[{"name":"员工数","value":["x"],"format":["164000 人<sup>520</sup><a name=\"ref_520\"></a>"]},{"name":"空","format":[""]}],
         "catalog":["<a href=\"#1\">公司历史</a>","主要产品"],"image":"https://x/y.jpg"}
        """#
        let l = BaikeClient.parse(Data(json.utf8), term: "apple")
        XCTAssertEqual(l?.title, "苹果公司")
        XCTAssertEqual(l?.abstract, "苹果公司（Apple Inc.）是美国公司")
        XCTAssertEqual(l?.card.count, 1)
        XCTAssertEqual(l?.card.first?.value, "164000 人")
        XCTAssertEqual(l?.sections, ["公司历史", "主要产品"])
        XCTAssertEqual(l?.hasOthers, true)
        XCTAssertTrue(l?.url.hasPrefix("https://baike.baidu.com/item/") ?? false)
        XCTAssertNil(BaikeClient.parse(Data("[]".utf8), term: "qzx"))
    }

    func testNetworkFlags() {
        XCTAssertTrue(BaikeClient.dictionary.isNetwork)
        XCTAssertFalse(BaikeClient.dictionary.isWikipedia)
    }
}
