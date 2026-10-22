import AppKit
import AVFoundation
import SwiftUI
import VocabCore
import os

private let reviewLog = Logger(subsystem: "io.github.vangie.vocab", category: "review")

/// One 背单词 session: plans the cards, picks a question type per card, scores answers and
/// writes ratings back to the wordbook.
@MainActor
final class ReviewSession: ObservableObject {
    static let shared = ReviewSession()
    static let capKey = "reviewDailyNewCap"
    static let introducedKey = "reviewNewIntroduced"

    enum Phase: Equatable { case idle, loading, check, asking, answered, summary }

    typealias Stats = SessionStats
    /// The answer just recorded for the current card (so 斩 in the answered state can replace it).
    private var lastAnswer: (rating: ReviewRating, correct: Bool, type: QuestionType)?

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var question: ReviewQuestion?
    @Published private(set) var queue = ReviewQueue(ids: [])
    @Published var revealed = false
    @Published var typed = ""
    /// 拼写: letters revealed by 提示 for the current question (any hint caps the rating at 模糊).
    @Published private(set) var hintsUsed = 0
    /// 拼写: answered via 不会，看答案 (feedback shows only the correct word).
    @Published private(set) var gaveUp = false
    @Published private(set) var chosen: Int?
    @Published private(set) var lastCorrect = false
    @Published private(set) var lastRating: ReviewRating?
    @Published private(set) var marks: [LetterMark] = []
    @Published private(set) var stats = Stats()
    @Published private(set) var preview = (reviews: 0, new: 0)

    private var items: [Int64: WordItem] = [:]
    private var factory: QuestionFactory?
    private var previousType: QuestionType?
    private var askedAt = Date()
    private var answeredOnce: Set<Int64> = []
    private let speech = AVSpeechSynthesizer()
    private var book: WordbookModel { .shared }

    static let retentionKey = "reviewDesiredRetention"
    static let learningKey = "reviewLearningSteps"
    static let relearningKey = "reviewRelearningSteps"

    /// Push Settings › 背单词 into the FSRS scheduler the wordbook uses.
    static func applySchedulerSettings() {
        let d = UserDefaults.standard
        var f = FSRS()
        if let r = d.object(forKey: retentionKey) as? Double, (0.7...0.99).contains(r) { f.desiredRetention = r }
        if let s = d.string(forKey: learningKey), let st = FSRS.parseSteps(s) { f.learningSteps = st }
        if let s = d.string(forKey: relearningKey), let st = FSRS.parseSteps(s) { f.relearningSteps = st }
        Scheduler.shared = f
    }

    static var dailyNewCap: Int { max(0, PlanModel.shared.plan.dailyNew) }

    private static var todayKey: String {
        StudyDay.key(Date())
    }
    static var introducedToday: Int {
        (UserDefaults.standard.dictionary(forKey: introducedKey)?[todayKey] as? Int) ?? 0
    }
    private static func noteIntroduced() {
        // Keep only today's count.
        UserDefaults.standard.set([todayKey: introducedToday + 1], forKey: introducedKey)
    }

    private static let reviewedKey = "reviewedToday"
    /// Distinct due reviews answered today.
    static var reviewedToday: Int {
        (UserDefaults.standard.dictionary(forKey: reviewedKey)?[todayKey] as? Int) ?? 0
    }
    private static func noteReviewed() {
        UserDefaults.standard.set([todayKey: reviewedToday + 1], forKey: reviewedKey)
    }
    /// Today's record and the streak, refreshed with the preview.
    @Published private(set) var today = DayRecord()
    @Published private(set) var streak = 0
    @Published private(set) var overall = PlanProgress()

    /// Word-list words not yet in the wordbook get a temporary negative id; they're written to the
    /// wordbook (source 词书·…) only when first answered.
    private var virtualSource: [Int64: ExamList] = [:]
    /// Words that get a quick 认识吗 first (middle bands of the last vocabulary test).
    private var quickCheck: Set<Int64> = []
    private var realID: [Int64: Int64] = [:]

    // MARK: 词书太简单？ First-sight outcomes of new list words (see ListEase).
    /// New words drawn from an exam list this session.
    private var newSource: [Int64: ExamList] = [:]
    /// Answered at first sight, not yet final (斩 right after answering still counts as 斩).
    private var firstPending: Set<Int64> = []
    private var firstDone: Set<Int64> = []
    @Published private(set) var ease = ListEase.load()
    /// Set when a list crossed the threshold during this round (shown in the summary).
    @Published private(set) var easeHitThisRound: ExamList?

    private func noteFirstSight(_ id: Int64, retired: Bool) {
        guard let l = newSource[id], !firstDone.contains(id) else { return }
        firstDone.insert(id); firstPending.remove(id)
        let before = ease.tooEasy(l)
        ease.record(l, retiredAtFirstSight: retired); ease.save()
        if !before && ease.tooEasy(l) { easeHitThisRound = l }
    }
    private func flushFirstSight() { for id in firstPending { noteFirstSight(id, retired: false) } }

    /// The active exam list that is too easy (most recently crossed first), if any.
    var tooEasyList: ExamList? {
        let active = PlanModel.shared.plan.sources.filter(\.enabled).compactMap { if case .list(let l) = $0.id { return l }; return nil }
        if let h = easeHitThisRound, active.contains(h), ease.tooEasy(h) { return h }
        return active.first { ease.tooEasy($0) }
    }
    func dismissEase(_ l: ExamList) { ease.dismiss(l); ease.save(); if easeHitThisRound == l { easeHitThisRound = nil } }
    /// Replace list `from` by `to` in the plan (same share). Learned/斩'd words are excluded globally by word.
    func switchList(from: ExamList, to: ExamList) {
        var p = PlanModel.shared.plan
        let ratio = p.sources.first { $0.id == .list(from) }?.ratio ?? 1
        for i in p.sources.indices {
            if p.sources[i].id == .list(from) { p.sources[i].enabled = false }
            if p.sources[i].id == .list(to) { p.sources[i].enabled = true; p.sources[i].ratio = ratio }
        }
        if !p.sources.contains(where: { $0.id == .list(to) }) { p.sources.append(PlanSource(id: .list(to), enabled: true, ratio: ratio)) }
        PlanModel.shared.plan = p
        easeHitThisRound = nil
        refreshPreview()
    }

    /// Size of a 「再学一组」 extra group: the daily new-word quota, or 10 if none.
    static var extraGroupSize: Int { let n = PlanModel.shared.plan.dailyNew; return n > 0 ? n : 10 }

    /// `extraNew` > 0: an extra group after today's tasks: that many new words plus every due review,
    /// ignoring the day's caps (progress counts as usual, so rings can pass 100%).
    private func plan(extraNew: Int = 0) -> [WordItem] {
        book.reload()
        let now = Date()
        let p = PlanModel.shared.plan
        // Words studied from a 词书 earlier (outside 生词本) that are now known-common (e.g. 'of' drawn
        // before the vocabulary test) are not quizzed; words the user saved to 生词本 always are.
        let common = PlanModel.shared.skippedCommonWords()
        let live = book.items.filter {
            !Scheduler.isMastered($0.review) && !($0.bookID == nil && common.contains($0.word.lowercased()))
        }
        let due = live.filter { !SessionPlanner.isNew($0) && $0.review.due <= now }.sorted { $0.review.due < $1.review.due }
        let reviews = extraNew > 0 ? due : Array(due.prefix(PlanMath.reviewsToday(plan: p, due: due.count)))
        let room = extraNew > 0 ? extraNew : PlanMath.newToday(plan: p, due: due.count, introducedToday: Self.introducedToday)
        virtualSource = [:]; quickCheck = []; realID = [:]; newSource = [:]
        guard room > 0 else { return reviews }
        let picks = PlanModel.shared.drawNew(count: room, liveItems: live)
        var fresh: [WordItem] = []
        var next: Int64 = -1
        let checkWords = PlanModel.shared.quickCheckWords
        for (w, src) in picks {
            if let it = book.items.first(where: { $0.word.caseInsensitiveCompare(w) == .orderedSame }) {
                if case .list(let l) = src { newSource[it.id] = l }
                fresh.append(it); continue
            }
            guard case .list(let l) = src else { continue }
            var it = WordItem(id: next, word: w, definition: WordLists.shared?.shortChinese(w) ?? "", dictionary: "",
                              context: nil, added: now,
                              review: ReviewState(state: .new, step: nil, stability: nil, difficulty: nil, intervalDays: 0,
                                                  repetitions: 0, lapses: 0, due: now, lastReviewed: nil))
            it.sourceApp = l.sourceApp
            virtualSource[next] = l
            newSource[next] = l
            if checkWords.contains(w.lowercased()) { quickCheck.insert(next) }
            fresh.append(it); next -= 1
        }
        return reviews + fresh
    }

    /// Write a word-list word into the wordbook the first time it is studied.
    private func materialize(_ id: Int64) -> Int64? {
        if id > 0 { return id }
        if let r = realID[id] { return r }
        guard let item = items[id], let l = virtualSource[id], let store = book.store else { return nil }
        // Studied, not collected: kept for its review state, outside 生词本.
        guard let added = try? store.addStudied(word: item.word, definition: item.definition, dictionary: "ECDICT",
                                                source: WordSource(app: l.sourceApp, title: l.title)) else { return nil }
        realID[id] = added.id
        return added.id
    }

    /// Counts for the start screen.
    func refreshPreview() {
        guard phase == .idle || phase == .summary else { return }
        let p = plan()
        preview = (p.filter { !SessionPlanner.isNew($0) }.count, p.filter(SessionPlanner.isNew).count)
        guard PlanModel.shared.plan.configured else { return }
        var log = DailyLog.load()
        let now = Date()
        log.snapshot(now, newLeft: preview.new, reviewsLeft: preview.reviews,
                     newDone: Self.introducedToday, reviewsDone: Self.reviewedToday,
                     newCap: PlanModel.shared.plan.dailyNew)
        log.save()
        today = log.today(now); streak = log.streak(now)
        overall = PlanModel.shared.progress()
    }

    // MARK: resume after relaunch

    /// An unfinished round from earlier today (shown as 「继续上一轮」).
    @Published private(set) var resumable: SessionSnapshot? = SessionSnapshot.load().flatMap { $0.resumable() ? $0 : nil }

    private func saveSnapshot() {
        guard phase != .idle, phase != .summary, !queue.finished else { return }
        let virtuals = virtualSource.compactMap { id, l -> SessionSnapshot.Virtual? in
            guard let it = items[id] else { return nil }
            return .init(id: id, word: it.word, definition: it.definition, list: l)
        }
        SessionSnapshot(date: Date(), queue: queue, stats: stats, virtuals: virtuals, realID: realID, newSource: newSource,
                        quickCheck: quickCheck, answeredOnce: answeredOnce, firstDone: firstDone).save()
    }

    /// Pick the saved round up where it was left (same queue, counts and retry-later cards).
    func resume() {
        guard let snap = resumable else { return }
        Self.applySchedulerSettings()
        book.reload()
        let now = Date()
        var its: [Int64: WordItem] = [:]
        virtualSource = [:]
        for v in snap.virtuals { virtualSource[v.id] = v.list }
        for id in Set(snap.queue.pending) {
            let real = id > 0 ? id : snap.realID[id]
            if let real, var it = book.items.first(where: { $0.id == real }) { it.id = id; its[id] = it; continue }
            if let v = snap.virtuals.first(where: { $0.id == id }) {
                var it = WordItem(id: id, word: v.word, definition: v.definition, dictionary: "", context: nil, added: now,
                                  review: ReviewState(state: .new, step: nil, stability: nil, difficulty: nil, intervalDays: 0,
                                                      repetitions: 0, lapses: 0, due: now, lastReviewed: nil))
                it.sourceApp = v.list.sourceApp
                its[id] = it
            }
        }
        items = its
        realID = snap.realID; newSource = snap.newSource; quickCheck = snap.quickCheck
        answeredOnce = snap.answeredOnce; firstDone = snap.firstDone; firstPending = []
        queue = snap.queue; stats = snap.stats
        previousType = nil; lastActivity = Date(); easeHitThisRound = nil
        // Cards deleted from the wordbook meanwhile can't be asked: skip them.
        while let c = queue.current, items[c] == nil { queue.retire() }
        resumable = nil
        let dicts = DictionarySelection.enabled()
        let thesaurus = DictionaryService.shared.availableDictionaries().first { $0.id == "com.apple.dictionary.OTE" }
        factory = QuestionFactory(dicts: dicts, thesaurus: thesaurus, book: book.items.map(\.word))
        if queue.finished { end() } else { loadCurrent() }
    }

    func discardResumable() { SessionSnapshot.clear(); resumable = nil }

    func start(extraNew: Int = 0) {
        Self.applySchedulerSettings()
        discardResumable()
        let p = plan(extraNew: extraNew)
        items = Dictionary(uniqueKeysWithValues: p.map { ($0.id, $0) })
        queue = ReviewQueue(ids: p.map(\.id))
        stats = Stats(); answeredOnce = []; previousType = nil; lastActivity = Date()
        firstPending = []; firstDone = []; easeHitThisRound = nil
        let dicts = DictionarySelection.enabled()
        let thesaurus = DictionaryService.shared.availableDictionaries().first { $0.id == "com.apple.dictionary.OTE" }
        factory = QuestionFactory(dicts: dicts, thesaurus: thesaurus, book: book.items.map(\.word))
        loadCurrent()
    }

    func end() { flushFirstSight(); SessionSnapshot.clear(); resumable = nil; activity(); lastActivity = nil; cancelAutoAdvance(); phase = .summary; question = nil; book.reload() }
    func reset() { phase = .idle; question = nil; refreshPreview() }

    private func loadCurrent() {
        flushFirstSight()
        saveSnapshot()
        revealed = false; typed = ""; hintsUsed = 0; gaveUp = false; chosen = nil; marks = []; lastRating = nil; lastAnswer = nil
        guard let id = queue.current, let item = items[id], let factory else { end(); return }
        if quickCheck.contains(id) {
            quickCheck.remove(id)
            checkWord = item.word
            phase = .check
            NotificationCenter.default.post(name: .vocabQuizQuestionShown, object: nil)
            return
        }
        phase = .loading
        let prev = previousType
        loadToken &+= 1
        let token = loadToken
        reviewLog.info("load \(item.word, privacy: .public) id=\(id)")
        Task.detached(priority: .userInitiated) {
            var rng = SystemRandomNumberGenerator()
            let m = factory.materials(for: item.word)
            let type = QuestionPicker.pick(stage: CardStage(item.review), available: m.available, previous: prev, using: &rng)
            let q = factory.make(item, type: type, using: &rng)
            await MainActor.run { self.present(q, token: token) }
        }
        // Watchdog: never leave the spinner up. If no question arrived (lookup stalled or the result was
        // dropped), retry once, then fall back to a self-rated recall card that needs no materials.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.loadToken == token, self.phase == .loading, self.question == nil || self.question?.itemID != id else { return }
            reviewLog.error("load timed out for \(item.word, privacy: .public); using fallback")
            var rng = SystemRandomNumberGenerator()
            self.present(factory.make(item, type: .recall, using: &rng), token: token)
        }
        // Warm up the next card while this one is answered.
        if queue.pending.count > 1, let next = items[queue.pending[1]] {
            Task.detached(priority: .utility) { _ = factory.materials(for: next.word) }
        }
    }

    private var loadToken = 0

    // MARK: 今日学习时长
    static let studyGoalKey = "dailyStudyGoalMinutes"
    static var studyGoalMinutes: Int { max(1, UserDefaults.standard.object(forKey: studyGoalKey) as? Int ?? 15) }
    private var lastActivity: Date?
    /// Called on every interaction in a session; time since the previous one counts unless idle (> 60 s).
    private func activity() {
        let now = Date()
        if let l = lastActivity {
            var log = DailyLog.load(); log.addStudy(now.timeIntervalSince(l), at: now); log.save()
            today = log.today(now)
        }
        lastActivity = now
    }

    private func present(_ q: ReviewQuestion, token: Int) {
        guard token == loadToken, phase == .loading else { return }   // a newer load superseded this one
        guard queue.current == q.itemID else {
            reviewLog.error("dropped question for \(q.word, privacy: .public): current card changed; reloading")
            loadCurrent(); return
        }
        question = q; previousType = q.type; askedAt = Date(); phase = .asking
        NotificationCenter.default.post(name: .vocabQuizQuestionShown, object: nil)
        if q.type != .meaningToWord { speak(q) }   // that one would give the answer away
    }

    /// Dictionaries for IPA: the enabled ones plus Oxford E–C (which has American IPA).
    static var phoneticDicts: [DictionaryInfo] {
        var d = DictionarySelection.enabled()
        if !d.contains(where: { $0.id == Self.ocdID }), let ocd = Self.ocd { d.append(ocd) }
        return d
    }
    private static let ocdID = "com.apple.dictionary.zh_CN-en.OCD"
    private static let ocd = DictionaryService.shared.availableDictionaries().first { $0.id == ocdID }

    /// Play a word: the dictionary's recording (American first) or the en-US voice.
    func pronounce(_ word: String, audio: URL?) {
        if let a = audio, AudioPlayer.shared.play(file: a) { return }
        let u = AVSpeechUtterance(string: word); u.voice = AVSpeechSynthesisVoice(language: "en-US")
        speech.stopSpeaking(at: .immediate); speech.speak(u)
    }

    func speak(_ q: ReviewQuestion? = nil) {
        guard let q = q ?? question else { return }
        if let a = q.audio, AudioPlayer.shared.play(file: a) { return }
        let u = AVSpeechUtterance(string: q.word); u.voice = AVSpeechSynthesisVoice(language: "en-US")
        speech.stopSpeaking(at: .immediate); speech.speak(u)
    }

    /// The word of the current 认识吗 check.
    @Published private(set) var checkWord: String?

    /// 认识吗: 认识 → 斩 (written to the wordbook as retired), 不认识 → learn it now.
    func answerCheck(known: Bool) {
        guard phase == .check, let id = queue.current else { return }
        activity()
        checkWord = nil
        noteFirstSight(id, retired: known)
        if known {
            if let rid = materialize(id) { _ = try? book.store?.retire(id: rid) }
            queue.retire(); stats.retired += 1
            if queue.finished { end() } else { loadCurrent() }
        } else {
            loadCurrent()
        }
    }

    // MARK: answering

    func choose(_ i: Int) {
        guard phase == .asking, let q = question, q.options.indices.contains(i) else { return }
        chosen = i
        finish(correct: q.isCorrectChoice(i))
    }

    func submitSpelling() {
        guard phase == .asking, let q = question, q.type == .spelling, !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        marks = SpellingCheck.diff(typed: typed.trimmingCharacters(in: .whitespaces), answer: q.word)
        finish(correct: SpellingCheck.isCorrect(typed, q.word))
    }

    /// 提示: reveal one more letter; the field is filled with that prefix (the user's own typing is kept
    /// when it already matches it).
    func hint() {
        guard phase == .asking, let q = question, q.type == .spelling, hintsUsed < SpellingHint.maxHints(q.word) else { return }
        activity()
        hintsUsed += 1
        let prefix = String(q.word.prefix(hintsUsed))
        if !typed.lowercased().hasPrefix(prefix.lowercased()) { typed = prefix }
    }

    /// 不会，看答案: show the spelling with the usual feedback; counts as 忘了 and goes to retry-later.
    func giveUpSpelling() {
        guard phase == .asking, let q = question, q.type == .spelling else { return }
        marks = []; gaveUp = true
        finish(correct: false)
    }

    func flip() {
        guard phase == .asking, question?.type == .recall, !revealed else { return }
        revealed = true
    }

    /// Recall (mature cards only): the user must rate 1 忘了 · 2 模糊 · 3 记得.
    func selfRate(_ r: ReviewRating) {
        guard phase == .asking, question?.type == .recall, revealed else { return }
        activity()
        apply(r, correct: r != .forgot)
        next()
    }

    private func finish(correct: Bool) {
        guard let q = question else { return }
        activity()
        let secs = Date().timeIntervalSince(askedAt)
        let r = RatingMap.capped(RatingMap.rating(correct: correct, seconds: secs, type: q.type, length: q.word.count),
                                 hinted: q.type == .spelling && hintsUsed > 0)
        apply(r, correct: correct)
        lastCorrect = correct
        phase = .answered
        if q.type == .meaningToWord || !correct { speak(q) }
        if correct && Self.autoAdvance { scheduleAutoAdvance() }
    }

    // MARK: 答对后自动下一题

    static let autoAdvanceKey = "autoAdvanceOnCorrect"
    static var autoAdvance: Bool { UserDefaults.standard.object(forKey: autoAdvanceKey) as? Bool ?? true }
    static let autoAdvanceDelayKey = "autoAdvanceDelay"
    static let autoAdvanceRange: ClosedRange<Double> = 1...5
    static var autoAdvanceDelay: TimeInterval {
        let v = UserDefaults.standard.object(forKey: autoAdvanceDelayKey) as? Double ?? 2
        return min(max(v, autoAdvanceRange.lowerBound), autoAdvanceRange.upperBound)
    }
    /// Countdown progress 0…1 while an auto-advance is pending (nil otherwise).
    @Published private(set) var autoProgress: Double?
    /// Hovering the answer area pauses the countdown.
    var autoPaused = false
    /// The pointer is over a 查词典 link: a click there looks the word up instead of moving on.
    var overLookupLink = false

    /// Show a word in 词典 mode. The session stays as it is (ReviewSession is shared), so switching
    /// back to 记词 resumes the same question; a pending auto-advance is cancelled.
    func lookUp(_ word: String) {
        cancelAutoAdvance()
        overLookupLink = false
        AppState.shared.mode = .lookup
        LookupModel.shared.search(word)
    }
    private var autoElapsed: TimeInterval = 0
    private var autoTimer: Timer?
    private var autoMonitor: Any?
    /// A correct answer waits ~0.8 s, then moves on; a click or any key moves on at once.
    private func scheduleAutoAdvance() {
        cancelAutoAdvance()
        let total = Self.autoAdvanceDelay, tick = 0.05
        autoElapsed = 0; autoProgress = 0
        autoTimer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.autoPaused { return }
                self.autoElapsed += tick
                self.autoProgress = min(1, self.autoElapsed / total)
                if self.autoElapsed >= total { self.next() }
            }
        }
        autoMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] e in
            guard let self, self.phase == .answered else { return e }
            if e.type == .leftMouseDown, self.overLookupLink { self.cancelAutoAdvance(); return e }
            if e.type == .leftMouseDown {
                // Only clicks in the review content, not the toolbar or other windows.
                guard let w = e.window, w.isMainWindow, e.locationInWindow.y < w.contentLayoutRect.maxY else { return e }
                // The quiz top bar (结束 · 斩) handles its own clicks: 斩 must still work during the countdown.
                if e.locationInWindow.y > w.contentLayoutRect.maxY - 64 { return e }
            }
            if e.type == .keyDown, e.modifierFlags.contains(.command) { return e }
            self.next()
            return nil
        }
    }
    private func cancelAutoAdvance() {
        autoTimer?.invalidate(); autoTimer = nil; autoProgress = nil
        if let m = autoMonitor { NSEvent.removeMonitor(m); autoMonitor = nil }
    }

    private func apply(_ r: ReviewRating, correct: Bool) {
        guard let q = question, let item = items[q.itemID] else { return }
        if !answeredOnce.contains(item.id) {
            if SessionPlanner.isNew(item) { Self.noteIntroduced() } else { Self.noteReviewed() }
        }
        if newSource[item.id] != nil, !firstDone.contains(item.id) { firstPending.insert(item.id) }
        answeredOnce.insert(item.id)
        if let rid = materialize(item.id), var updated = try? book.store?.review(id: rid, rating: r) {
            updated.id = item.id   // keep the session's key
            items[item.id] = updated
        }
        lastRating = r
        stats.record(r, correct: correct, type: q.type)
        lastAnswer = (r, correct, q.type)
        queue.answer(correct: correct)
        saveSnapshot()
    }

    func next() {
        cancelAutoAdvance()
        activity()
        guard phase == .answered || phase == .asking else { return }
        if queue.finished { end() } else { loadCurrent() }
    }

    /// 斩 / 已掌握: retire the word for good.
    func retire() {
        guard let q = question, phase == .asking || phase == .answered else { return }
        cancelAutoAdvance()   // else the countdown would skip the next card
        activity()
        // Retiring overwrites the review state just written by the answer (Scheduler.retire).
        if let rid = materialize(q.itemID) { _ = try? book.store?.retire(id: rid) }
        noteFirstSight(q.itemID, retired: true)   // no-op unless this is the word's first sight
        if phase == .asking { queue.retire() }
        else {
            queue.dropCurrentRequeue(q.itemID)   // also removes a wrong answer's relearning requeue
            if let a = lastAnswer { stats.unrecord(a.rating, correct: a.correct, type: a.type) }
        }
        lastAnswer = nil
        stats.retired += 1
        if queue.finished { end() } else { loadCurrent() }
    }
}

extension ReviewSession {
    /// Offscreen renders only (`--render-quiz`): a detached session showing one question.
    /// Never touches the wordbook, stats or the shared session.
    static func preview(_ q: ReviewQuestion, chosen: Int?, typed: String? = nil, total: Int = 20, done: Int = 7) -> ReviewSession {
        let s = ReviewSession()
        var queue = ReviewQueue(ids: (1...Int64(total)).map { $0 })
        for _ in 0..<done { queue.answer(correct: true) }
        s.queue = queue
        s.question = q
        if q.type == .recall && chosen == -1 { s.checkWord = q.word; s.phase = .check; return s }
        if q.type == .spelling, let t = typed {
            s.typed = t; s.marks = SpellingCheck.diff(typed: t, answer: q.word)
            s.lastCorrect = SpellingCheck.isCorrect(t, q.word); s.lastRating = s.lastCorrect ? .good : .forgot
            s.phase = .answered; return s
        }
        if let c = chosen {
            s.chosen = c; s.lastCorrect = q.isCorrectChoice(c)
            s.lastRating = s.lastCorrect ? .good : .forgot
            s.phase = .answered
        } else { s.phase = .asking }
        return s
    }
}


extension Notification.Name {
    /// A new 记词 question (or 认识吗 card) is on screen: the quiz takes the keyboard back.
    static let vocabQuizQuestionShown = Notification.Name("VocabQuizQuestionShown")
}

/// Who gets the keyboard while a 记词 quiz is on screen.
enum QuizFocus {
    @MainActor static var quizActive: Bool {
        let st = AppState.shared, ph = ReviewSession.shared.phase
        return st.mode == .words && st.wordGroup == .today && [.asking, .answered, .check].contains(ph)
    }
    /// Take focus from the search field when a quiz is active and the user didn't click/⌘F into it.
    static func shouldReclaim(quizActive: Bool, searchFocused: Bool, explicit: Bool) -> Bool {
        quizActive && searchFocused && !explicit
    }
}
