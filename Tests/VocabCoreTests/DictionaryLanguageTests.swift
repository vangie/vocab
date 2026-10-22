import XCTest
@testable import VocabCore

final class DictionaryLanguageTests: XCTestCase {
    typealias G = DictionaryLanguageGroup
    func testFromMetadata() {
        XCTAssertEqual(G.groups(languages: ["zh_CN", "en"], name: "牛津英汉汉英词典"), [.simplified, .english])
        XCTAssertEqual(G.groups(languages: ["zh-Hant"], name: "x"), [.traditional])
        XCTAssertEqual(G.groups(languages: ["zh_TW"], name: "x"), [.traditional])
        XCTAssertEqual(G.groups(languages: ["yue", "en"], name: "牛津粵英雙語詞典"), [.traditional, .english])
        XCTAssertEqual(G.groups(languages: ["ja"], name: "x"), [.japanese])
        XCTAssertEqual(G.groups(languages: ["fr"], name: "x"), [.other])
    }
    func testFromName() {
        XCTAssertEqual(G.groups(languages: [], name: "现代汉语规范词典"), [.simplified])
        XCTAssertEqual(G.groups(languages: [], name: "商務新詞典（全新版）"), [.traditional])
        XCTAssertEqual(G.groups(languages: [], name: "五南國語活用辭典"), [.traditional])
        XCTAssertEqual(G.groups(languages: [], name: "譯典通英漢雙向字典"), [.traditional, .english])
        XCTAssertEqual(G.groups(languages: [], name: "漢英對照成語詞典"), [.traditional, .english])
        XCTAssertEqual(G.groups(languages: [], name: "英譯廣東口語詞典"), [.traditional, .english])
        XCTAssertEqual(G.groups(languages: [], name: "スーパー大辞林"), [.japanese])
        XCTAssertEqual(G.groups(languages: [], name: "超級クラウン中日辞典 / クラウン日中辞典"), [.japanese])
        XCTAssertEqual(G.groups(languages: [], name: "ウィズダム英和辞典 / ウィズダム和英辞典"), [.japanese, .english])
        XCTAssertEqual(G.groups(languages: [], name: "麦克米伦英语词典第二版", id: "Macmillan2"), [.english])
        XCTAssertEqual(G.groups(languages: [], name: "朗文当代高级英语辞典", id: "LDOCE5"), [.english, .simplified])
        XCTAssertEqual(G.groups(languages: [], name: "Oxford Dictionary of English"), [.english])
        XCTAssertEqual(G.groups(languages: [], name: "Oxford German Dictionary"), [.english, .other])
        XCTAssertEqual(G.groups(languages: [], name: "Duden-Wissensnetz deutsche Sprache"), [.other])
        XCTAssertEqual(G.groups(languages: [], name: "Wikipedia", id: "com.apple.dictionary.Wikipedia"), [.english, .simplified])
    }
    func testFilterMigration() {
        XCTAssertEqual(G.decodeFilter(["mandarin", "english"]), [.simplified, .english])
        XCTAssertEqual(G.decodeFilter(["traditional", "bogus"]), [.traditional])
    }
    func testMergeKeepsHiddenSlots() {
        // a b C d E  (visible: a, C, E) → drag E to top: E b a d C
        XCTAssertEqual(G.merge(global: ["a", "b", "C", "d", "E"], visibleInNewOrder: ["E", "a", "C"]), ["E", "b", "a", "d", "C"])
        XCTAssertEqual(G.merge(global: ["a", "b"], visibleInNewOrder: ["a", "b"]), ["a", "b"])
        XCTAssertEqual(G.merge(global: ["a", "b", "c"], visibleInNewOrder: ["c", "a", "b"]), ["c", "a", "b"])
    }
    func testDefault() { XCTAssertEqual(G.defaultSelection, [.simplified, .english]) }
}

final class DictionaryLanguageOverrideTests2: XCTestCase {
    func testMOEIsTraditional() {
        XCTAssertEqual(DictionaryLanguageGroup.groups(languages: [], name: "重编国语辞典", id: "x"), [.traditional])
    }
    func testSpeakerScriptInjected() {
        let s = EntryHTML.prepare("<html><head></head><body/></html>", resourceDirectory: nil)
        XCTAssertTrue(s.contains("v-spk")); XCTAssertTrue(s.contains("播放美音"))
    }
}

final class DictionaryLanguageCantoneseRemovalTests: XCTestCase {
    func testCantoneseDroppedFromSavedFilter() {
        XCTAssertEqual(DictionaryLanguageGroup.decodeFilter(["cantonese", "english", "mandarin"]), [.english, .simplified])
        XCTAssertNil(DictionaryLanguageGroup(rawValue: "cantonese"))
    }
    func testCantoneseByScript() {
        XCTAssertEqual(DictionaryLanguageGroup.groups(languages: ["zh_HK"], name: "x"), [.traditional])
        XCTAssertEqual(DictionaryLanguageGroup.groups(languages: [], name: "粤语词典"), [.simplified])
    }
}
