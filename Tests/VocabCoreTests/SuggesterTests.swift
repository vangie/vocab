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
