import AppKit
import AVFoundation
import SwiftUI
import VocabCore

/// One 背单词 session: plans the cards, picks a question type per card, scores answers and
/// writes ratings back to the wordbook.
@MainActor
final class ReviewSession: ObservableObject {
    static let shared = ReviewSession()
    static let capKey = "reviewDailyNewCap"
    static let introducedKey = "reviewNewIntroduced"

    enum Phase: Equatable { case idle, loading, check, asking, answered, summary }

    struct Stats {
        var answered = 0, correct = 0, wrong = 0, retired = 0
        var ratings: [ReviewRating: Int] = [:]
        var byType: [QuestionType: (right: Int, total: Int)] = [:]
        var started = Date()
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var question: ReviewQuestion?
    @Published private(set) var queue = ReviewQueue(ids: [])
    @Published var revealed = false
    @Published var typed = ""
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
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.string(from: Date())
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

    private func plan() -> [WordItem] {
        book.reload()
        let now = Date()
        let p = PlanModel.shared.plan
        let live = book.items.filter { !Scheduler.isMastered($0.review) }
        let due = live.filter { !SessionPlanner.isNew($0) && $0.review.due <= now }.sorted { $0.review.due < $1.review.due }
        let reviews = Array(due.prefix(PlanMath.reviewsToday(plan: p, due: due.count)))
        let room = PlanMath.newToday(plan: p, due: due.count, introducedToday: Self.introducedToday)
        virtualSource = [:]; quickCheck = []; realID = [:]
        guard room > 0 else { return reviews }
        let picks = PlanModel.shared.drawNew(count: room, liveItems: live)
        var fresh: [WordItem] = []
        var next: Int64 = -1
        let checkWords = PlanModel.shared.quickCheckWords
        for (w, src) in picks {
            if let it = book.items.first(where: { $0.word.caseInsensitiveCompare(w) == .orderedSame }) { fresh.append(it); continue }
            guard case .list(let l) = src else { continue }
            var it = WordItem(id: next, word: w, definition: WordLists.shared?.shortChinese(w) ?? "", dictionary: "",
                              context: nil, added: now,
                              review: ReviewState(state: .new, step: nil, stability: nil, difficulty: nil, intervalDays: 0,
                                                  repetitions: 0, lapses: 0, due: now, lastReviewed: nil))
            it.sourceApp = l.sourceApp
            virtualSource[next] = l
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
                     newDone: Self.introducedToday, reviewsDone: Self.reviewedToday)
        log.save()
        today = log.today(now); streak = log.streak(now)
        overall = PlanModel.shared.progress()
    }

    func start() {
        Self.applySchedulerSettings()
        let p = plan()
        items = Dictionary(uniqueKeysWithValues: p.map { ($0.id, $0) })
        queue = ReviewQueue(ids: p.map(\.id))
        stats = Stats(); answeredOnce = []; previousType = nil
        let dicts = DictionarySelection.enabled()
        let thesaurus = DictionaryService.shared.availableDictionaries().first { $0.id == "com.apple.dictionary.OTE" }
        factory = QuestionFactory(dicts: dicts, thesaurus: thesaurus, book: book.items.map(\.word))
        loadCurrent()
    }

    func end() { cancelAutoAdvance(); phase = .summary; question = nil; book.reload() }
    func reset() { phase = .idle; question = nil; refreshPreview() }

    private func loadCurrent() {
        revealed = false; typed = ""; chosen = nil; marks = []; lastRating = nil
        guard let id = queue.current, let item = items[id], let factory else { end(); return }
        if quickCheck.contains(id) {
            quickCheck.remove(id)
            checkWord = item.word
            phase = .check
            return
        }
        phase = .loading
        let prev = previousType
        Task.detached(priority: .userInitiated) {
            var rng = SystemRandomNumberGenerator()
            let m = factory.materials(for: item.word)
            let type = QuestionPicker.pick(stage: CardStage(item.review), available: m.available, previous: prev, using: &rng)
            let q = factory.make(item, type: type, using: &rng)
            await MainActor.run { self.present(q) }
        }
        // Warm up the next card while this one is answered.
        if queue.pending.count > 1, let next = items[queue.pending[1]] {
            Task.detached(priority: .utility) { _ = factory.materials(for: next.word) }
        }
    }

    private func present(_ q: ReviewQuestion) {
        guard queue.current == q.itemID else { return }
        question = q; previousType = q.type; askedAt = Date(); phase = .asking
        if q.type != .meaningToWord { speak(q) }   // that one would give the answer away
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
        checkWord = nil
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
        finish(correct: i == q.correctIndex)
    }

    func submitSpelling() {
        guard phase == .asking, let q = question, q.type == .spelling, !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        marks = SpellingCheck.diff(typed: typed.trimmingCharacters(in: .whitespaces), answer: q.word)
        finish(correct: SpellingCheck.isCorrect(typed, q.word))
    }

    func flip() {
        guard phase == .asking, question?.type == .recall, !revealed else { return }
        revealed = true
    }

    /// Recall (mature cards only): the user must rate 1 忘了 · 2 模糊 · 3 记得.
    func selfRate(_ r: ReviewRating) {
        guard phase == .asking, question?.type == .recall, revealed else { return }
        apply(r, correct: r != .forgot)
        next()
    }

    private func finish(correct: Bool) {
        guard let q = question else { return }
        let secs = Date().timeIntervalSince(askedAt)
        let r = RatingMap.rating(correct: correct, seconds: secs, type: q.type, length: q.word.count)
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
            if e.type == .leftMouseDown {
                // Only clicks in the review content, not the toolbar or other windows.
                guard let w = e.window, w.isMainWindow, e.locationInWindow.y < w.contentLayoutRect.maxY else { return e }
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
        answeredOnce.insert(item.id)
        if let rid = materialize(item.id), var updated = try? book.store?.review(id: rid, rating: r) {
            updated.id = item.id   // keep the session's key
            items[item.id] = updated
        }
        lastRating = r
        stats.answered += 1
        if correct { stats.correct += 1 } else { stats.wrong += 1 }
        stats.ratings[r, default: 0] += 1
        var t = stats.byType[q.type] ?? (0, 0); t.total += 1; if correct { t.right += 1 }; stats.byType[q.type] = t
        queue.answer(correct: correct)
    }

    func next() {
        cancelAutoAdvance()
        guard phase == .answered || phase == .asking else { return }
        if queue.finished { end() } else { loadCurrent() }
    }

    /// 斩 / 已掌握: retire the word for good.
    func retire() {
        guard let q = question, phase == .asking || phase == .answered else { return }
        if let rid = materialize(q.itemID) { _ = try? book.store?.retire(id: rid) }
        if phase == .asking { queue.retire() }
        else { queue.dropCurrentRequeue(q.itemID) }
        stats.retired += 1
        if queue.finished { end() } else { loadCurrent() }
    }
}
