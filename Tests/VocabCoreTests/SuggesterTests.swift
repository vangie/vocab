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
