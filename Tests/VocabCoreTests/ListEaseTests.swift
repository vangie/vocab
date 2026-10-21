import XCTest
@testable import VocabCore

final class ListEaseTests: XCTestCase {
    func testThresholdNeeds50SamplesAnd70Percent() {
        var e = ListEase()
        for i in 0..<49 { e.record(.zk, retiredAtFirstSight: i % 10 < 8) }   // 80% but only 49
        XCTAssertFalse(e.tooEasy(.zk))
        e.record(.zk, retiredAtFirstSight: true)                              // 50 samples
        XCTAssertTrue(e.tooEasy(.zk))
        var f = ListEase()
        for i in 0..<60 { f.record(.gk, retiredAtFirstSight: i % 10 < 6) }   // 60%
        XCTAssertFalse(f.tooEasy(.gk))
        e.dismiss(.zk); XCTAssertFalse(e.tooEasy(.zk))
    }

    func testRollingWindow() {
        var e = ListEase()
        for _ in 0..<100 { e.record(.zk, retiredAtFirstSight: false) }
        for _ in 0..<70 { e.record(.zk, retiredAtFirstSight: true) }
        XCTAssertEqual(e.samples(.zk), 100)
        XCTAssertEqual(e.share(.zk), 0.7, accuracy: 1e-9)
        XCTAssertTrue(e.tooEasy(.zk))
    }

    func testRecommendation() {
        XCTAssertEqual(ListEase.recommend(after: .zk, estimate: nil), .gk)
        XCTAssertEqual(ListEase.recommend(after: .zk, estimate: 5000), .ky)
        XCTAssertEqual(ListEase.recommend(after: .gk, estimate: 2000), .cet4)    // never easier than next
        XCTAssertEqual(ListEase.recommend(after: .gk, estimate: 20000), .gre)
        XCTAssertEqual(ListEase.recommend(after: .zk, estimate: 3000, exclude: [.gk]), .cet4)
        XCTAssertNil(ListEase.recommend(after: .gre, estimate: nil))
    }

    func testPersistence() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "le-\(UUID())"))
        var e = ListEase(); e.record(.cet4, retiredAtFirstSight: true); e.dismiss(.gk); e.save(d)
        XCTAssertEqual(ListEase.load(d), e)
    }
}
