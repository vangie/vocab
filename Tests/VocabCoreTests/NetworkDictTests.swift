import XCTest
@testable import VocabCore

/// Regression: with Wikipedia enabled in Settings › 词典, quiz distractor search went through DCS's
/// network Wikipedia dictionary and hung, leaving 记词's loading spinner up forever.
final class NetworkDictTests: XCTestCase {
    func testNetworkDictionariesNeverSearchedViaDCS() throws {
        let svc = DictionaryService.shared
        guard let wiki = svc.availableDictionaries().first(where: \.isNetwork) else {
            throw XCTSkip("no Wikipedia dictionary on this machine")
        }
        let t0 = Date()
        XCTAssertEqual(svc.headwords("of", method: 1, in: [wiki], maxPerDictionary: 10), [])
        XCTAssertFalse(svc.hasEntry("of", in: [wiki]))
        let f = QuestionFactory(dicts: [wiki] + svc.activeDictionaries().filter { !$0.isNetwork }, thesaurus: nil, book: [])
        _ = f.materials(for: "of")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)
    }
}
