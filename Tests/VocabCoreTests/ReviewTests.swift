import XCTest
@testable import VocabCore

final class DistractorTests: XCTestCase {
    func testAdaptYieldsLookalikesNotSynonyms() {
        let pool = ["adopt", "adept", "adjust", "modify", "alter", "adapted", "adaptable", "adaptation",
                    "adage", "apt", "Adam", "adaptor", "zebra", "a-dapt"]
        let syn: Set<String> = ["adjust", "modify", "alter", "acclimatize"]
        let top = Distractors.rank(target: "adapt", candidates: pool, synonyms: syn, limit: 3).map(\.word)
        XCTAssertTrue(top.contains("adopt"), "\(top)")
        XCTAssertTrue(top.contains("adept"), "\(top)")
        for bad in ["adjust", "modify", "alter", "adapted", "adaptable", "adaptation", "adaptor", "Adam", "zebra"] {
            XCTAssertFalse(top.contains(bad), "\(bad) in \(top)")
        }
    }

    func testVowelVariantsCoverClassicConfusables() {
        XCTAssertTrue(Distractors.variants("adapt").contains("adopt"))
        XCTAssertTrue(Distractors.variants("adapt").contains("adept"))
        XCTAssertTrue(Distractors.variants("affect").contains("effect"))
        XCTAssertTrue(Distractors.variants("dessert").contains("desert"))
    }

    func testPhoneticKeyAndFamily() {
        XCTAssertEqual(Distractors.phoneticKey("affect"), Distractors.phoneticKey("effect"))
        XCTAssertTrue(Distractors.isSameFamily("adapt", "adaptation"))
        XCTAssertTrue(Distractors.isSameFamily("decide", "decision"))
        XCTAssertFalse(Distractors.isSameFamily("advice", "advise"))
        XCTAssertFalse(Distractors.isSameFamily("adapt", "adopt"))
    }

    func testWordbookAndSharedRootBoost() {
        let r = Distractors.rank(target: "inspect", candidates: ["insect", "inspire", "respect"], book: ["respect"], limit: 3)
        XCTAssertEqual(r.first?.word, "insect")   // one letter off still wins
        XCTAssertTrue(r.map(\.word).contains("respect"))
    }

    func testThesaurusParsing() {
        let t = "adapt verb 1 we've adapted the hotels. modify, alter, make alterations to, change, adjust; informal tweak. ANTONYMS preserve."
        let w = Distractors.thesaurusWords(t)
        XCTAssertTrue(w.isSuperset(of: ["modify", "alter", "adjust", "tweak", "change"]))
        XCTAssertFalse(w.contains("preserve"))
    }

    func testChineseGlossOverlapMeansSynonym() {
        XCTAssertTrue(GlossExtractor.overlaps("调整…以适用", "调整，调节"))
        XCTAssertFalse(GlossExtractor.overlaps("（使）适应，（使）适合", "收养，领养"))
    }

    func testGlossExtraction() {
        let ldoce = #"<span class="SIGNPOST">child<span class="cn_txt"> 孩子</span></span><span class="DEF LDOCE_switch_lang"> to take someone else’s <a class="defRef" href="x">child</a> into your home</span><span class="DEF LDOCE_switch_lang"> <span class="cn_txt"> 收养，领养</span></span>"#
        XCTAssertEqual(GlossExtractor.chinese(fromHTML: ldoce), "收养，领养")
        XCTAssertEqual(GlossExtractor.english(fromHTML: ldoce), "to take someone else’s child into your home")
        let ocd = #"<span class="trg"><span d:def="1" class="trans">适应 <d:def></d:def></span><span class="trans ty_pinyin">shìyìng </span></span>"#
        XCTAssertEqual(GlossExtractor.chinese(fromHTML: ocd), "适应")
    }
}

final class HyphenationTests: XCTestCase {
    func testDictionaryHeadwords() {
        XCTAssertEqual(Hyphenation.fromDictionaryText("a·dapt /əˈdæpt/ verb", word: "adapt"), ["a", "dapt"])
        XCTAssertEqual(Hyphenation.fromDictionaryText("At·lan·tic2 /ətˈlæntɪk/", word: "Atlantic"), ["At", "lan", "tic"])
        XCTAssertEqual(Hyphenation.fromDictionaryText("requestrequestre‧quest W2 /rɪˈkwest/", word: "request"), ["re", "quest"])
        XCTAssertNil(Hyphenation.fromDictionaryText("ap·ple", word: "adapt"))
    }

    func testSystemFallbackSplitsLongWords() {
        let s = Hyphenation.system("information")
        XCTAssertEqual(s.joined(), "information")
        XCTAssertGreaterThanOrEqual(s.count, 3, "\(s)")
    }

    func testSplitOptions() {
        let o = Hyphenation.options(correct: ["ac", "com", "mo", "date"])!
        XCTAssertEqual(o.count, 4)
        XCTAssertEqual(o[0], ["ac", "com", "mo", "date"])
        XCTAssertEqual(Set(o.map { $0.joined(separator: "|") }).count, 4)
        for x in o { XCTAssertEqual(x.joined(), "accommodate") }
        XCTAssertNil(Hyphenation.options(correct: ["cat"]))
    }
}

final class RootTableTests: XCTestCase {
    func testMatches() {
        XCTAssertEqual(RootTable.matches("inspect").first?.morpheme.meaning, "看")
        XCTAssertEqual(RootTable.matches("request").first?.form, "quest")
        XCTAssertTrue(RootTable.matches("transport").contains { $0.form == "trans" && $0.morpheme.kind == .prefix })
        XCTAssertTrue(RootTable.matches("hopeless").contains { $0.form == "less" && $0.morpheme.kind == .suffix })
        XCTAssertFalse(RootTable.matches("complement").contains { $0.morpheme.kind == .root && $0.form == "ment" })
    }

    func testNoMatchMeansSkip() {
        XCTAssertTrue(RootTable.matches("cat").isEmpty)
        XCTAssertTrue(RootTable.matches("Atlantic").isEmpty)   // proper nouns skipped
        var m = WordMaterials(); m.gloss = Gloss(chinese: "猫")
        XCTAssertFalse(m.available.contains(.roots))
    }

    func testTableSize() { XCTAssertGreaterThanOrEqual(RootTable.all.count, 200) }
}

final class RatingAndSessionTests: XCTestCase {
    func testRatingMapping() {
        XCTAssertEqual(RatingMap.rating(correct: false, seconds: 1, type: .wordToMeaning, length: 5), .forgot)
        XCTAssertEqual(RatingMap.rating(correct: true, seconds: 2, type: .wordToMeaning, length: 5), .easy)
        XCTAssertEqual(RatingMap.rating(correct: true, seconds: 5, type: .wordToMeaning, length: 5), .good)
        XCTAssertEqual(RatingMap.rating(correct: true, seconds: 20, type: .wordToMeaning, length: 5), .fuzzy)
        // Spelling allows more time for longer words.
        XCTAssertEqual(RatingMap.rating(correct: true, seconds: 6, type: .spelling, length: 12), .easy)
        XCTAssertEqual(RatingMap.rating(correct: true, seconds: 6, type: .spelling, length: 3), .good)
    }

    func testEasyGrowsFasterThanGood() {
        let now = Date(timeIntervalSince1970: 0)
        let s = ReviewState.new(now: now)
        XCTAssertGreaterThan(Scheduler.next(s, rating: .easy, now: now).intervalDays, Scheduler.next(s, rating: .good, now: now).intervalDays)
        XCTAssertTrue(Scheduler.isMastered(Scheduler.retire(s, now: now)))
    }

    func testWrongAnswerComesBackLater() {
        var q = ReviewQueue(ids: [1, 2, 3, 4, 5])
        q.answer(correct: false)
        XCTAssertEqual(q.pending, [2, 3, 4, 1, 5])
        q.answer(correct: true); q.answer(correct: true); q.answer(correct: true)
        XCTAssertEqual(q.current, 1)
        q.answer(correct: true); q.retire()
        XCTAssertTrue(q.finished)
        XCTAssertEqual(q.wrong[1], 1)
    }

    func testPlannerReviewsFirstThenCappedNew() {
        let now = Date(timeIntervalSince1970: 100_000)
        func item(_ id: Int64, reps: Int, due: TimeInterval, added: TimeInterval) -> WordItem {
            var r = ReviewState.new(now: Date(timeIntervalSince1970: due)); r.repetitions = reps
            if reps > 0 { r.lastReviewed = Date(timeIntervalSince1970: 0); r.state = .review; r.stability = 3; r.difficulty = 5 }
            return WordItem(id: id, word: "w\(id)", definition: "", dictionary: "", context: nil, added: Date(timeIntervalSince1970: added), review: r)
        }
        var mastered = item(9, reps: 3, due: 0, added: 0); mastered.review = Scheduler.retire(mastered.review, now: now)
        let items = [item(1, reps: 0, due: 0, added: 10), item(2, reps: 0, due: 0, added: 5), item(3, reps: 2, due: 50_000, added: 0),
                     item(4, reps: 1, due: 200_000, added: 0), item(5, reps: 0, due: 0, added: 1), mastered]
        XCTAssertEqual(SessionPlanner.plan(items, now: now, newCap: 2, newIntroducedToday: 0).map(\.id), [3, 5, 2])
        XCTAssertEqual(SessionPlanner.plan(items, now: now, newCap: 2, newIntroducedToday: 2).map(\.id), [3])
    }

    func testPickerAdaptsToStage() {
        var rng = SystemRandomNumberGenerator()
        let all = Set(QuestionType.allCases)
        for _ in 0..<50 {
            XCTAssertNotEqual(QuestionPicker.pick(stage: .new, available: all, previous: nil, using: &rng), .spelling)
            XCTAssertNotEqual(QuestionPicker.pick(stage: .mature, available: all, previous: nil, using: &rng), .wordToMeaning)
            XCTAssertNotEqual(QuestionPicker.pick(stage: .learning, available: all, previous: .recall, using: &rng), .recall)
        }
        XCTAssertEqual(QuestionPicker.pick(stage: .new, available: [.recall], previous: .recall, using: &rng), .recall)
    }

    func testSyllablesNeverAsked() {
        var rng = SystemRandomNumberGenerator()
        let all = Set(QuestionType.allCases)
        for stage in [CardStage.new, .learning, .mature] {
            XCTAssertNil(QuestionPicker.weights(stage)[.syllables])
            for _ in 0..<300 { XCTAssertNotEqual(QuestionPicker.pick(stage: stage, available: all, previous: nil, using: &rng), .syllables) }
            XCTAssertNotEqual(QuestionPicker.pick(stage: stage, available: [.syllables, .spelling], previous: nil, using: &rng), .syllables)
        }
    }

    func testRecallOnlyForMatureAndRare() {
        var rng = SystemRandomNumberGenerator()
        let all = Set(QuestionType.allCases)
        for _ in 0..<300 {
            XCTAssertNotEqual(QuestionPicker.pick(stage: .new, available: all, previous: nil, using: &rng), .recall)
            XCTAssertNotEqual(QuestionPicker.pick(stage: .learning, available: all, previous: nil, using: &rng), .recall)
        }
        // A new card with recall + spelling only falls back to an objective type.
        XCTAssertEqual(QuestionPicker.pick(stage: .new, available: [.recall, .spelling], previous: nil, using: &rng), .spelling)
        // Mature: recall share stays ≤ 15%, also when few types are available.
        for avail: Set<QuestionType> in [all, [.recall, .spelling], [.recall, .roots]] {
            var n = 0
            for _ in 0..<4000 where QuestionPicker.pick(stage: .mature, available: avail, previous: nil, using: &rng) == .recall { n += 1 }
            XCTAssertLessThan(Double(n) / 4000, 0.18, "\(avail)")
        }
    }

    func testSpellingDiffAndContext() {
        let d = SpellingCheck.diff(typed: "acomodate", answer: "accommodate")
        XCTAssertEqual(d.filter { $0.kind == .missing }.count, 2)
        XCTAssertEqual(String(d.filter { $0.kind != .extra }.map(\.char)), "accommodate")
        XCTAssertTrue(SpellingCheck.isCorrect(" Adapt ", "adapt"))
        XCTAssertEqual(ContextHint.blank("They adapted quickly to Adapt.", word: "adapt"), "They ＿＿＿ quickly to ＿＿＿.")
    }
}

final class ConfusableTests: XCTestCase {
    func testListSize() { XCTAssertGreaterThanOrEqual(Confusables.groups.count, 150) }

    func testAffectGetsEffectDespiteSharedGloss() {
        let r = Distractors.rank(target: "affect", candidates: ["afflict", "affix", "affront", "effect"], limit: 3).map(\.word)
        XCTAssertEqual(r.first, "effect")
        XCTAssertTrue(Distractors.keep(target: "affect", candidate: "effect",
                                       targetGloss: Gloss(chinese: "影响", english: "to do something that produces an effect"),
                                       candidateGloss: Gloss(chinese: "效应；影响；结果", english: "a change that is caused by an event"),
                                       synonyms: ["effect"]))   // even if a thesaurus listed it
    }

    func testAdviseGetsAdvice() {
        let r = Distractors.rank(target: "advise", candidates: ["advance", "adverse", "adverb"], limit: 3).map(\.word)
        XCTAssertEqual(r.first, "advice")
        XCTAssertTrue(Distractors.keep(target: "advise", candidate: "advice",
                                       targetGloss: Gloss(chinese: "劝告，建议"), candidateGloss: Gloss(chinese: "意见，建议；忠告，劝告")))
    }

    func testAdaptStillExcludesSynonyms() {
        let top = Distractors.rank(target: "adapt", candidates: ["adjust", "modify", "adage", "apt"],
                                   synonyms: ["adjust", "modify"], limit: 3).map(\.word)
        XCTAssertEqual(Array(top.prefix(2)).sorted(), ["adept", "adopt"])   // curated group adapt/adopt/adept
        XCTAssertFalse(top.contains("adjust")); XCTAssertFalse(top.contains("modify"))
        XCTAssertFalse(Distractors.keep(target: "adapt", candidate: "adjust",
                                        targetGloss: Gloss(chinese: "调整…以适用"), candidateGloss: Gloss(chinese: "调整，调节"),
                                        synonyms: ["adjust"]))
    }

    func testRelaxedGlossFilter() {
        // Strong spelling link + partial overlap → kept; weak link + overlap → dropped; near-identical → dropped.
        XCTAssertTrue(Distractors.keep(target: "abroad", candidate: "aboard",
                                       targetGloss: Gloss(chinese: "在国外"), candidateGloss: Gloss(chinese: "在船上")))
        XCTAssertFalse(Distractors.keep(target: "big", candidate: "enormous",
                                        targetGloss: Gloss(chinese: "大的，巨大的"), candidateGloss: Gloss(chinese: "巨大的，庞大的")))
        XCTAssertFalse(Distractors.keep(target: "hard", candidate: "harsh",
                                        targetGloss: Gloss(chinese: "严厉的"), candidateGloss: Gloss(chinese: "（非常）严厉的")))
    }

    func testStepParsing() {
        XCTAssertEqual(FSRS.parseSteps("1m 10m"), [60, 600])
        XCTAssertEqual(FSRS.parseSteps("30s, 1h 1d"), [30, 3600, 86_400])
        XCTAssertEqual(FSRS.parseSteps("5"), [300])
        XCTAssertNil(FSRS.parseSteps("1x"))
        XCTAssertEqual(FSRS.formatSteps([60, 600, 86_400]), "1m 10m 1d")
    }
}
