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
            if run.askingCheck { run.answerCheck(it.correct.first!) } else { run.answer(run.bands[it.band].hi <= 3000) }
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
            if run2.askingCheck { run2.answerCheck("x") } else { run2.answer(true) }
        }
        XCTAssertLessThan(run2.result().estimate, 1500)
    }

    func testUndoDuringReading() throws {
        let list = try XCTUnwrap(HanziList.shared)
        var rng = SystemRandomNumberGenerator()
        var run = HanziTestRun(list: list, using: &rng)
        while !(run.current!.check) { run.answer(false) }
        let i = run.answered
        run.answer(true); XCTAssertTrue(run.askingCheck)
        run.undo(); XCTAssertFalse(run.askingCheck); XCTAssertEqual(run.answered, i); XCTAssertNil(run.current?.known)
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

    func testGlossParser() {
        XCTAssertEqual(HanziGloss.firstSense("明 1 míng ①形 亮（跟“暗”相对）。月明星稀 | 明珠 ②动 特指天亮。", char: "明"), "亮（跟“暗”相对）")
        XCTAssertNil(HanziGloss.firstSense("鸳 yuān （鴛）名 指鸳鸯。双鸳戏水", char: "鸳"))   // compound, falls through to 新华
        XCTAssertEqual(HanziGloss.firstSense("鸳yuān ㄩㄢˉ仓颉 NUPYM　基本解释1〔～鸯〕水鸟，比鸭小，栖息于池沼之上。", char: "鸳"), "水鸟，比鸭小，栖息于池沼之上")
        XCTAssertNil(HanziGloss.firstSense("", char: "x"))
        XCTAssertEqual(HanziGloss.firstSense("匆 cōng （悤）（怱）形 急促；急忙。匆忙", char: "匆"), "急促")
        XCTAssertNil(HanziGloss.firstSense("基 jī ①名 基础①。墙基", char: "基"))
        XCTAssertNil(HanziGloss.firstSense("妤 yú 见“婕（jié）妤”。", char: "妤"))
        XCTAssertEqual(HanziGloss.firstSense("哧 chī 拟声 模拟笑声。", char: "哧"), "模拟笑声")
    }

    func testSpotChecksMixReadingAndMeaning() throws {
        let list = try XCTUnwrap(HanziList.shared)
        XCTAssertGreaterThan(list.chars[0].radical, 0)
        var rng = SystemRandomNumberGenerator()
        let run = HanziTestRun(list: list, using: &rng)     // bundled English glosses
        let checks = run.items.filter(\.check)
        let meaning = checks.filter { $0.checkKind == .meaning }
        XCTAssertGreaterThan(meaning.count, 0); XCTAssertGreaterThan(checks.count - meaning.count, 0)
        for m in meaning {
            XCTAssertEqual(m.choices.count, 4); XCTAssertEqual(Set(m.choices).count, 4)
            XCTAssertEqual(m.correct.count, 1); XCTAssertTrue(m.choices.contains(m.correct.first!))
        }
    }

    func testDistractorsShareRadical() throws {
        let list = try XCTUnwrap(HanziList.shared)
        var rng = SystemRandomNumberGenerator()
        let run = HanziTestRun(list: list, using: &rng)
        let c = try XCTUnwrap(list.chars.first { $0.char == "河" })
        let m = try XCTUnwrap(run.meaningChoices(for: c, using: &rng))
        let sameRadical = Set(list.chars.filter { $0.radical == c.radical && $0.char != "河" }.map(\.gloss))
        XCTAssertGreaterThanOrEqual(m.choices.filter { sameRadical.contains($0) }.count, 2, "\(m.choices)")
    }

    func testFailedMeaningCheckDiscounts() throws {
        let list = try XCTUnwrap(HanziList.shared)
        var rng = SystemRandomNumberGenerator()
        func run(failMeaning: Bool) -> Int {
            var r = HanziTestRun(list: list, using: &rng)
            while !r.finished {
                let it = r.current!
                if r.askingCheck {
                    r.answerCheck(it.checkKind == .meaning && failMeaning ? "x" : it.correct.first!)
                } else { r.answer(true) }
            }
            return r.result().estimate
        }
        XCTAssertGreaterThan(run(failMeaning: false), 6000)
        XCTAssertLessThan(run(failMeaning: true), 5000)
    }
}
