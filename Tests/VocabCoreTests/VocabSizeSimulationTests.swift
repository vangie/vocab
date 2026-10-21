import XCTest
@testable import VocabCore

/// Synthetic test-takers for the adaptive 词汇量 / 识字量 tests. Guards against the soft-label
/// collapse (failed meaning checks discounting every 认识 and stalling the test near its start rank).
final class VocabSizeSimulationTests: XCTestCase {
    struct Profile { let name: String; let know: (Int) -> Double; let falseAlarms: Int; let checkPass: Double; let unsure: Bool }

    static func simulate(_ p: Profile, seed: UInt64) -> (estimate: Int, maxRank: Int, items: Int) {
        var rng = Adaptive.Gen(seed: seed)
        var cands: [(word: String, rank: Int)] = []
        for r in 1...20000 where Double.random(in: 0..<1, using: &rng) < 0.87 { cands.append(("w\(r)", r)) }
        var t = VocabTestRun(candidates: cands, pseudo: (0..<40).map { "zq\($0)x" }, using: &rng)
        t.meaning = { _ in (right: "R", choices: ["R", "A", "B", "C"]) }
        var fas = p.falseAlarms, maxRank = 0, steps = 0
        while let it = t.current, steps < 300 {
            steps += 1
            if t.askingCheck { t.answerCheck(Double.random(in: 0..<1, using: &rng) < p.checkPass ? "R" : (p.unsure ? "" : "A")); continue }
            if let r = it.rank { maxRank = max(maxRank, r); t.answer(Double.random(in: 0..<1, using: &rng) < p.know(r)) }
            else { t.answer(fas > 0); fas = max(0, fas - 1) }
        }
        return (t.result().estimate, maxRank, t.answeredReal)
    }

    static let eightK: (Int) -> Double = { $0 < 8000 ? 1 : $0 < 12000 ? 0.5 : 0 }
    static let profiles: [Profile] = [
        .init(name: "<8k + 50% to 12k, 0 FA, checks 100%", know: eightK, falseAlarms: 0, checkPass: 1, unsure: false),
        .init(name: "<8k + 50% to 12k, 1 FA, checks 100%", know: eightK, falseAlarms: 1, checkPass: 1, unsure: false),
        .init(name: "<8k + 50% to 12k, 0 FA, checks 70%", know: eightK, falseAlarms: 0, checkPass: 0.7, unsure: false),
        .init(name: "<8k + 50% to 12k, 1 FA, checks 60%", know: eightK, falseAlarms: 1, checkPass: 0.6, unsure: false),
        .init(name: "<8k + 50% to 12k, 0 FA, checks 60% 不确定", know: eightK, falseAlarms: 0, checkPass: 0.6, unsure: true),
        .init(name: "<6k only, 0 FA, checks 100%", know: { $0 < 6000 ? 1 : 0 }, falseAlarms: 0, checkPass: 1, unsure: false),
        .init(name: "<3k only, 0 FA, checks 100%", know: { $0 < 3000 ? 1 : 0 }, falseAlarms: 0, checkPass: 1, unsure: false),
        .init(name: "overclaimer: <3k, 3 FA, checks 30%", know: { $0 < 3000 ? 1 : 0.4 }, falseAlarms: 3, checkPass: 0.3, unsure: false),
    ]

    func results(_ p: Profile) -> [(estimate: Int, maxRank: Int, items: Int)] {
        (1...10).map { Self.simulate(p, seed: UInt64($0) * 7919) }
    }
    func median(_ xs: [Int]) -> Int { xs.sorted()[xs.count / 2] }

    func testTable() {
        for p in Self.profiles {
            let r = results(p)
            print("SIM | \(p.name) | median \(median(r.map(\.estimate))) | min \(r.map(\.estimate).min()!) | max \(r.map(\.estimate).max()!) | maxRank median \(median(r.map(\.maxRank))) | items \(median(r.map(\.items)))")
        }
    }

    func testCleanEightKProfileEstimatesEightToTenK() {
        let r = results(Self.profiles[0])
        XCTAssert((7500...10500).contains(median(r.map(\.estimate))), "\(r.map(\.estimate))")
        XCTAssertGreaterThan(median(r.map(\.maxRank)), 8000)   // the adaptive step reaches the 8k–12k ranks
        XCTAssertLessThanOrEqual(r.map(\.items).max()!, Adaptive.maxItems)
    }

    func testFailedChecksNoLongerCollapse() {
        for i in [2, 3, 4] {
            let r = results(Self.profiles[i])
            XCTAssertGreaterThanOrEqual(r.map(\.estimate).min()!, 4800, "\(Self.profiles[i].name): \(r.map(\.estimate))")
            XCTAssertGreaterThanOrEqual(median(r.map(\.estimate)), 6000, "\(Self.profiles[i].name)")
        }
    }

    func testOneFalseAlarmCostsLittle() {
        XCTAssertGreaterThanOrEqual(median(results(Self.profiles[1]).map(\.estimate)), 6500)
    }

    func testSmallerVocabulariesStayHonest() {
        XCTAssert((5000...7200).contains(median(results(Self.profiles[5]).map(\.estimate))))
        XCTAssert((2400...3800).contains(median(results(Self.profiles[6]).map(\.estimate))))
        XCTAssertLessThan(median(results(Self.profiles[7]).map(\.estimate)), 4500)   // still capped by checks + FA
    }

    func testLabelsAndCeiling() {
        XCTAssertEqual(Adaptive.label(known: false, checkCorrect: nil, unsure: nil), 0)
        XCTAssertEqual(Adaptive.label(known: true, checkCorrect: nil, unsure: nil), 1)
        XCTAssertEqual(Adaptive.label(known: true, checkCorrect: false, unsure: false), 0.5)
        XCTAssertGreaterThan(Adaptive.label(known: true, checkCorrect: false, unsure: true), 0.5)
        XCTAssertEqual(Adaptive.ceiling(passed: 0, failed: 0, unsure: 0), 1)
        XCTAssertGreaterThan(Adaptive.ceiling(passed: 0, failed: 1, unsure: 0), 0.8)   // one early miss: no collapse
        XCTAssertEqual(Adaptive.ceiling(passed: 0, failed: 10, unsure: 0), Adaptive.ceilingFloor)
        XCTAssertGreaterThan(Adaptive.ceiling(passed: 3, failed: 0, unsure: 3), Adaptive.ceiling(passed: 3, failed: 3, unsure: 0))
    }

    func testEasyDistractorsShareNoCharacters() {
        var rng = Adaptive.Gen(seed: 1)
        let glosses = ["apple": "苹果", "river": "河流", "table": "桌子", "happy": "快乐的", "relish": "享受", "enjoy": "享受；喜爱", "chair": "椅子"]
        let d = EasyDistractors.pick(word: "relish", right: "享受；喜欢", pool: Array(glosses.keys), gloss: { glosses[$0] }, using: &rng)
        XCTAssertEqual(d?.count, 3)
        XCTAssertFalse(d!.contains { $0.contains("享") || $0.contains("喜") })
    }

    func testHanziFailedChecksNoLongerCollapse() {
        let sim = HanziTests()
        for t in [2500.0] {
            var est: [Double] = []
            for seed in 1...8 {
                let (r, truth) = sim.simulateHanzi(threshold: t, checkOK: 0.6, meaningOK: 0.6, seed: UInt64(seed) * 31 + 7)
                est.append(Double(r.result().estimate) / truth)
            }
            print("SIM | 识字量 threshold \(Int(t)), checks 60% | ratio to truth: \(est.map { String(format: "%.2f", $0) }.joined(separator: " "))")
            XCTAssertGreaterThan(est.min()!, 0.5, "\(est)")
        }
    }
}
