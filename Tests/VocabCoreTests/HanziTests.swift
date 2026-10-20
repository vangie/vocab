import XCTest
@testable import VocabCore

final class HanziTests: XCTestCase {
    func testBundledListLoads() throws {
        let l = try XCTUnwrap(HanziList.shared)
        XCTAssertGreaterThan(l.chars.count, 6000)
        XCTAssertEqual(l.chars.first?.char, "的")
        XCTAssertEqual(l.chars[1].readings, ["yī"])
        XCTAssertTrue(l.chars.allSatisfy { !$0.readings.isEmpty })
    }

    func testPinyin() {
        XCTAssertEqual(Pinyin.split("hǎo").base, "hao"); XCTAssertEqual(Pinyin.split("hǎo").tone, 3)
        XCTAssertEqual(Pinyin.apply("hao", tone: 4), "hào")
        XCTAssertEqual(Pinyin.apply("liu", tone: 2), "liú")
        XCTAssertEqual(Pinyin.apply("lüe", tone: 4), "lüè")
        XCTAssertEqual(Pinyin.apply("gou", tone: 3), "gǒu")
    }

    func testChoicesExcludeOtherReadings() {
        var rng = SystemRandomNumberGenerator()
        let all = ["de", "dí", "dì", "yī", "shì", "bù", "le", "zài", "rén"]
        for _ in 0..<50 {
            let c = HanziTestRun.choices(for: ["de", "dí", "dì"], all: all, using: &rng)
            XCTAssertEqual(c.count, 4); XCTAssertEqual(Set(c).count, 4)
            XCTAssertEqual(c.filter { ["de", "dí", "dì"].contains($0) }, ["de"])
        }
    }

    func testVerifiedShare() {
        XCTAssertEqual(HanziTestScoring.verified(correct: 0, of: 0), 1)
        XCTAssertEqual(HanziTestScoring.verified(correct: 10, of: 10), 1)
        XCTAssertLessThan(HanziTestScoring.verified(correct: 2, of: 10), 0.2)   // ≈ guessing
    }

    func testFullRunEstimates() throws {
        let list = try XCTUnwrap(HanziList.shared)
        var rng = SystemRandomNumberGenerator()
        var run = HanziTestRun(list: list, using: &rng)
        XCTAssertEqual(run.items.count, HanziTestRun.perBand * run.bands.count)
        // Simulated reader: knows the 3000 most frequent characters and reads them correctly.
        func step() {
            let it = run.current!
            if run.askingReading { run.answerReading(it.readings[0]) } else { run.answer(run.bands[it.band].hi <= 3000) }
        }
        while !run.finished { step() }
        run.startRound2(using: &rng)
        while !run.finished { step() }
        let r = run.result()
        XCTAssertEqual(r.estimate, 3000, accuracy: 300)
        XCTAssertEqual(r.falseAlarm, 0, accuracy: 0.001)

        // Same answers but every reading check wrong → heavy correction.
        var run2 = HanziTestRun(list: list, using: &rng)
        while !run2.finished {
            let it = run2.current!
            if run2.askingReading { run2.answerReading("x") } else { run2.answer(true) }
        }
        XCTAssertLessThan(run2.result().estimate, 1500)
    }

    func testUndoDuringReading() throws {
        let list = try XCTUnwrap(HanziList.shared)
        var rng = SystemRandomNumberGenerator()
        var run = HanziTestRun(list: list, using: &rng)
        while !(run.current!.check) { run.answer(false) }
        let i = run.answered
        run.answer(true); XCTAssertTrue(run.askingReading)
        run.undo(); XCTAssertFalse(run.askingReading); XCTAssertEqual(run.answered, i); XCTAssertNil(run.current?.known)
    }

    func testHanziResultsStoredSeparately() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hz-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try WordStore(url: url)
        let r = HanziTestScoring.score([], bands: HanziTestScoring.bands(total: 6000))
        try store.saveHanziResult(r)
        XCTAssertEqual(try store.hanziResults().count, 1)
        XCTAssertEqual(try store.testResults().count, 0)
    }
}
