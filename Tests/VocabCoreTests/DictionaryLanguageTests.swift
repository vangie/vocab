import XCTest
@testable import VocabCore

final class DictionaryLanguageTests: XCTestCase {
    typealias G = DictionaryLanguageGroup
    func testFromMetadata() {
        XCTAssertEqual(G.groups(languages: ["zh_CN", "en"], name: "牛津英汉汉英词典"), [.mandarin, .english])
        XCTAssertEqual(G.groups(languages: ["yue", "en"], name: "牛津粵英雙語詞典"), [.cantonese, .english])
        XCTAssertEqual(G.groups(languages: ["ja"], name: "x"), [.japanese])
        XCTAssertEqual(G.groups(languages: ["fr"], name: "x"), [.other])
    }
    func testFromName() {
        XCTAssertEqual(G.groups(languages: [], name: "康熙字典"), [.mandarin])
        XCTAssertEqual(G.groups(languages: [], name: "英譯廣東口語詞典"), [.cantonese, .english])
        XCTAssertEqual(G.groups(languages: [], name: "スーパー大辞林"), [.japanese])
        XCTAssertEqual(G.groups(languages: [], name: "超級クラウン中日辞典 / クラウン日中辞典"), [.japanese, .mandarin])
        XCTAssertEqual(G.groups(languages: [], name: "Oxford Dictionary of English"), [.english])
        XCTAssertEqual(G.groups(languages: [], name: "Oxford German Dictionary"), [.english, .other])
        XCTAssertEqual(G.groups(languages: [], name: "Duden-Wissensnetz deutsche Sprache"), [.other])
        XCTAssertEqual(G.groups(languages: [], name: "Wikipedia", id: "com.apple.dictionary.Wikipedia"), [.english, .mandarin])
    }
    func testMergeKeepsHiddenSlots() {
        // a b C d E  (visible: a, C, E) → drag E to top: E b a d C
        XCTAssertEqual(G.merge(global: ["a", "b", "C", "d", "E"], visibleInNewOrder: ["E", "a", "C"]), ["E", "b", "a", "d", "C"])
        XCTAssertEqual(G.merge(global: ["a", "b"], visibleInNewOrder: ["a", "b"]), ["a", "b"])
        XCTAssertEqual(G.merge(global: ["a", "b", "c"], visibleInNewOrder: ["c", "a", "b"]), ["c", "a", "b"])
    }
    func testDefault() { XCTAssertEqual(G.defaultSelection, [.mandarin, .english]) }
}
