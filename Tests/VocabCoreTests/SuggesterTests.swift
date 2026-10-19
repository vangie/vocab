import XCTest
@testable import VocabCore

final class SuggesterTests: XCTestCase {
    func testRankExactFirstThenShortSingleWords() {
        let r = Suggester.rank(["vocal cords", "Vocab", "vocabulary", "vocab", "vocal", "VOC"], query: "vocab")
        XCTAssertEqual(r.first, "Vocab")          // exact (case-insensitive), first form kept
        XCTAssertEqual(r.filter { $0.lowercased() == "vocab" }.count, 1)   // deduped
        XCTAssertLessThan(r.firstIndex(of: "vocabulary")!, r.count)
    }

    func testRankPrefersSingleWordsOverPhrases() {
        let r = Suggester.rank(["Atlantic Ocean, the", "Atlantic", "Atlanta"], query: "atlant")
        XCTAssertEqual(r, ["Atlanta", "Atlantic", "Atlantic Ocean, the"])
    }

    func testDistance() {
        XCTAssertEqual(Suggester.distance("vacab", "vocab"), 1)
        XCTAssertEqual(Suggester.distance("recieve", "receive"), 1)   // transposition
        XCTAssertEqual(Suggester.distance("", "abc"), 3)
        XCTAssertEqual(Suggester.distance("kitten", "sitting"), 3)
    }

    func testLemma() {
        XCTAssertEqual(Suggester.lemma("running"), "run")
        XCTAssertEqual(Suggester.lemma("mice"), "mouse")
        XCTAssertNil(Suggester.lemma("run"))
    }

    // Integration tests against the dictionaries installed on this Mac.
    private func ldoce() throws -> [DictionaryInfo] {
        let d = DictionaryService.shared.availableDictionaries().filter { $0.id == "LDOCE5" || $0.id.hasSuffix("zh_CN-en.OCD") }
        if d.isEmpty { throw XCTSkip("LDOCE5 / Oxford Chinese not installed") }
        return d
    }

    func testPrefixAutocomplete() throws {
        let r = Suggester.suggest("voc", in: try ldoce(), guesses: { _ in [] })
        XCTAssertTrue(r.matches.contains("vocab"))
        XCTAssertTrue(r.matches.contains("vocabulary"))
        XCTAssertTrue(r.matches.allSatisfy { $0.lowercased().hasPrefix("voc") })
    }

    func testSpellingCorrection() throws {
        let r = Suggester.suggest("vacab", in: try ldoce(), guesses: { _ in [] })
        XCTAssertTrue(r.matches.isEmpty)
        XCTAssertEqual(r.spelling.first, "vocab")
        XCTAssertTrue(r.spelling.contains("vocabulary"))
    }

    func testInflectionFallback() throws {
        let d = try ldoce()
        let r = Suggester.lookupWithFallback("appalled", in: d)
        XCTAssertFalse(r.entries.isEmpty)
        XCTAssertTrue(Suggester.suggest("appalled", in: d, guesses: { _ in [] }).matches.contains("appal"))
    }
}

final class WordUnderCursorTests: XCTestCase {
    func testChineseTokenizerPicksWordAtOffset() {
        let t = "还有个好消息：刚才重新编译装图标"
        let ns = t as NSString
        XCTAssertEqual(WordUnderCursor.word(in: t, at: 0)?.word, "还有")
        let w = WordUnderCursor.word(in: t, at: ns.range(of: "消息").location)?.word ?? ""
        XCTAssertTrue(w.contains("消息"), w)
        let w2 = WordUnderCursor.word(in: t, at: ns.range(of: "编译").location + 1)?.word ?? ""
        XCTAssertTrue(w2.contains("编译"), w2)
        XCTAssertNotEqual(w2, "还有")
    }

    func testEnglishOffsetToWord() {
        let t = "The quick brown fox."
        XCTAssertEqual(WordUnderCursor.word(in: t, at: 11)?.word, "brown")
        XCTAssertEqual(WordUnderCursor.word(in: t, at: 18)?.word, "fox")
    }

    func testIndexForPointFindsCharacterByBounds() {
        // Two lines of 10 chars, 10pt wide, 20pt tall; index 9 is a zero-size newline.
        let rects: [CGRect?] = (0..<20).map { i in
            if i == 9 { return nil }
            return CGRect(x: CGFloat(i % 10) * 10, y: CGFloat(i / 10) * 20, width: 10, height: 20)
        }
        let b: (Int) -> CGRect? = { rects[$0] }
        XCTAssertEqual(WordUnderCursor.indexForPoint(CGPoint(x: 35, y: 10), count: 20, bounds: b), 3)
        XCTAssertEqual(WordUnderCursor.indexForPoint(CGPoint(x: 72, y: 30), count: 20, bounds: b), 17)
        XCTAssertEqual(WordUnderCursor.indexForPoint(CGPoint(x: 2, y: 2), count: 20, bounds: b), 0)
        XCTAssertNil(WordUnderCursor.indexForPoint(CGPoint(x: 500, y: 500), count: 20, bounds: b))
    }
}

final class ClickSuppressorTests: XCTestCase {
    func testSuppressOnlyRightAfterThreeFingerContact() {
        XCTAssertTrue(ClickSuppressor.shouldSuppress(secondsSinceThreeTouch: 0.0, window: 0.25))
        XCTAssertTrue(ClickSuppressor.shouldSuppress(secondsSinceThreeTouch: 0.2, window: 0.25))
        XCTAssertFalse(ClickSuppressor.shouldSuppress(secondsSinceThreeTouch: 0.5, window: 0.25))
        XCTAssertFalse(ClickSuppressor.shouldSuppress(secondsSinceThreeTouch: 1e9, window: 0.25))
    }
}

final class DictionaryPrefsTests: XCTestCase {
    func testSpliceReplacesBodyKeepsHead() {
        let r = "<html><head><style>x</style></head><body><p>old</p></body></html>"
        let t = "<html><head/><body class=\"n\"><p>new</p></body></html>"
        XCTAssertEqual(DictionaryPrefs.splice(rendered: r, transformed: t),
                       "<html><head><style>x</style></head><body class=\"n\"><p>new</p></body></html>")
    }

    func testOverridesStoredOnlyWhenDifferentAndTransformApplies() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-\(UUID().uuidString).dictionary")
        let res = dir.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": "test.dict", "DCSDictionaryXSL": "t.xsl",
                                  "DCSDictionaryDefaultPrefs": ["display-zh": "1", "version": "1"]]
        info.write(to: dir.appendingPathComponent("Contents/Info.plist"), atomically: true)
        try """
        <xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:template match="@*|node()"><xsl:copy><xsl:apply-templates select="@*|node()"/></xsl:copy></xsl:template>
        <xsl:template match="span[@class='zh']"><xsl:if test="$display-zh = '1'"><xsl:copy-of select="."/></xsl:if></xsl:template>
        </xsl:stylesheet>
        """.write(to: res.appendingPathComponent("t.xsl"), atomically: true, encoding: .utf8)
        let p = try XCTUnwrap(DictionaryPrefs(bundleURL: dir))
        let store = UserDefaults(suiteName: "vocab.tests.\(UUID().uuidString)")!
        p.save(p.systemEffective, store)
        XCTAssertTrue(p.vocabOverrides(store).isEmpty)
        XCTAssertFalse(p.needsOwnTransform(store))
        var v = p.systemEffective; v["display-zh"] = "0"
        p.save(v, store)
        XCTAssertEqual(p.vocabOverrides(store), ["display-zh": "0"])
        XCTAssertTrue(p.needsOwnTransform(store))
        let raw = "<html><head/><body><p>word <span class=\"zh\">词</span></p></body></html>"
        let off = try XCTUnwrap(p.transform(rawXML: raw, params: p.effective(store)))
        XCTAssertFalse(off.contains("词"))
        let on = try XCTUnwrap(p.transform(rawXML: raw, params: p.systemEffective))
        XCTAssertTrue(on.contains("词"))
    }
}

final class RecentListTests: XCTestCase {
    func testDisplayedOrderStaysUntilRefresh() {
        var r = RecentList(["a", "b", "c"])
        r.record("c")
        XCTAssertEqual(r.displayed, ["a", "b", "c"])   // click didn't reorder the shown list
        XCTAssertEqual(r.stored, ["c", "a", "b"])      // but history remembers it
        r.record("new")
        XCTAssertEqual(r.displayed, ["a", "b", "c"])
        r.refresh()
        XCTAssertEqual(r.displayed, ["new", "c", "a", "b"])
    }
}

final class SidebarContentTests: XCTestCase {
    func testQueryChangeReplacesListEvenWithZeroResults() {
        let recents = ["NICAM", "NiCad", "niqab"]
        XCTAssertEqual(SidebarContent.make(query: "nica", suggestionsFor: "nica", words: ["NiCad", "NICAM"], recents: recents),
                       .suggestions(query: "nica", words: ["NiCad", "NICAM"]))
        // New query, old suggestions still in memory: never show them, and never fall back to recents.
        XCTAssertEqual(SidebarContent.make(query: "的等待", suggestionsFor: "nica", words: ["NiCad", "NICAM"], recents: recents),
                       .noSuggestions(query: "的等待"))
        XCTAssertEqual(SidebarContent.make(query: "的等待", suggestionsFor: "的等待", words: [], recents: recents),
                       .noSuggestions(query: "的等待"))
        XCTAssertEqual(SidebarContent.make(query: " ", suggestionsFor: nil, words: [], recents: recents), .recents(recents))
    }
}
