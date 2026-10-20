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

    func simulateHanzi(threshold t: Double, slope: Double = 3, checkOK: Double = 1, meaningOK: Double = 1, claimPseudo: Double = 0, seed: UInt64) -> (HanziTestRun, Double) {
        let list = HanziList.shared!
        var rng = SeededRNG(seed)
        var run = HanziTestRun(list: list, using: &rng)
        let truth = (1...list.chars.count).reduce(0.0) { $0 + Adaptive.sigma(log(Double($1)), mu: log(t), s: slope) }
        while let it = run.current {
            if run.askingCheck {
                let ok = Double.random(in: 0..<1, using: &rng) < (it.checkKind == .meaning ? meaningOK : checkOK)
                run.answerCheck(ok ? it.correct.first! : "x"); continue
            }
            if it.isPseudo { run.answer(Double.random(in: 0..<1, using: &rng) < claimPseudo); continue }
            run.answer(Double.random(in: 0..<1, using: &rng) < Adaptive.sigma(log(Double(it.rank)), mu: log(t), s: slope))
        }
        return (run, truth)
    }

    func testAdaptiveHanziWithin10PercentAndShorter() {
        let fixedDesign = 50   // old 2-round design: 40 + 10 characters (plus spot-checks)
        for t in [800.0, 2500, 4500] {
            var errs: [Double] = [], counts: [Int] = []
            for seed in 1...15 {
                let (r, truth) = simulateHanzi(threshold: t, seed: UInt64(seed) * 104729 + UInt64(t))
                errs.append(abs(Double(r.result().estimate) - truth) / truth); counts.append(r.items.filter { !$0.isPseudo }.count)
            }
            print("SIM \(t): median err \(errs.sorted()[errs.count / 2]) items \(counts.min()!)–\(counts.max()!) mean \(Double(counts.reduce(0,+))/Double(counts.count))")
            XCTAssertLessThan(errs.sorted()[errs.count / 2], 0.10, "threshold \(t): \(errs)")
            XCTAssertLessThan(counts.max()!, fixedDesign, "threshold \(t): \(counts)")
        }
    }

    func testPseudoCharacters() {
        XCTAssertGreaterThan(HanziPseudo.shared.count, 100)
        let (honest, _) = simulateHanzi(threshold: 2500, seed: 5)
        let ps = honest.items.filter(\.isPseudo)
        XCTAssertGreaterThan(ps.count, 2); XCTAssertTrue(ps.allSatisfy { !$0.check && $0.char.count == 2 })
        XCTAssertEqual(honest.result().reliability, 0)
        let (liar, _) = simulateHanzi(threshold: 2500, claimPseudo: 1, seed: 5)
        XCTAssertEqual(liar.result().reliability, 2)
        XCTAssertLessThan(Double(liar.result().estimate), Double(honest.result().estimate) * 0.85)
        XCTAssertNotNil(honest.result().crossCheck)
    }

    func testSpotChecksMixAndDiscount() {
        let (r, _) = simulateHanzi(threshold: 2500, seed: 9)
        let checked = r.items.filter(\.check)
        XCTAssertTrue(checked.contains { $0.checkKind == .reading }); XCTAssertTrue(checked.contains { $0.checkKind == .meaning })
        for m in checked where m.checkKind == .meaning { XCTAssertEqual(Set(m.choices).count, 4); XCTAssertTrue(m.choices.contains(m.correct.first!)) }
        let honest = Double(r.result().estimate)
        let badMeaning = Double(simulateHanzi(threshold: 2500, meaningOK: 0, seed: 9).0.result().estimate)
        let badReading = Double(simulateHanzi(threshold: 2500, checkOK: 0, seed: 9).0.result().estimate)
        XCTAssertLessThan(badMeaning, honest * 0.8); XCTAssertLessThan(badReading, honest * 0.8)
    }

    func testUndoDuringCheck() throws {
        let list = try XCTUnwrap(HanziList.shared)
        var rng = SeededRNG(1)
        var run = HanziTestRun(list: list, using: &rng)
        let first = run.current!.char
        run.answer(true); XCTAssertTrue(run.askingCheck)          // 1st 认识 is checked
        run.undo(); XCTAssertFalse(run.askingCheck); XCTAssertEqual(run.current?.char, first); XCTAssertEqual(run.answered, 0)
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

    func testDistractorsShareRadical() throws {
        let list = try XCTUnwrap(HanziList.shared)
        var rng = SystemRandomNumberGenerator()
        let run = HanziTestRun(list: list, using: &rng)
        let c = try XCTUnwrap(list.chars.first { $0.char == "河" })
        let m = try XCTUnwrap(run.meaningChoices(for: c, using: &rng))
        let sameRadical = Set(list.chars.filter { $0.radical == c.radical && $0.char != "河" }.map(\.gloss))
        XCTAssertGreaterThanOrEqual(m.choices.filter { sameRadical.contains($0) }.count, 2, "\(m.choices)")
    }

}
