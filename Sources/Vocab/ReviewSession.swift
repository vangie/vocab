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

    enum Phase: Equatable { case idle, loading, asking, answered, summary }

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

    static var dailyNewCap: Int {
        let v = UserDefaults.standard.object(forKey: capKey) as? Int
        return max(0, v ?? 20)
    }

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

    private func plan() -> [WordItem] {
        book.reload()
        return SessionPlanner.plan(book.items, now: Date(), newCap: Self.dailyNewCap, newIntroducedToday: Self.introducedToday)
    }

    /// Counts for the start screen.
    func refreshPreview() {
        guard phase == .idle || phase == .summary else { return }
        let p = plan()
        preview = (p.filter { !SessionPlanner.isNew($0) }.count, p.filter(SessionPlanner.isNew).count)
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

    func end() { phase = .summary; question = nil; book.reload() }
    func reset() { phase = .idle; question = nil; refreshPreview() }

    private func loadCurrent() {
        revealed = false; typed = ""; chosen = nil; marks = []; lastRating = nil
        guard let id = queue.current, let item = items[id], let factory else { end(); return }
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

    /// Recall: the user rates themselves (1 忘了 · 2 模糊 · 3 记得 · 4 简单).
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
    }

    private func apply(_ r: ReviewRating, correct: Bool) {
        guard let q = question, let item = items[q.itemID] else { return }
        if SessionPlanner.isNew(item) && !answeredOnce.contains(item.id) { Self.noteIntroduced() }
        answeredOnce.insert(item.id)
        if let updated = try? book.store?.review(id: item.id, rating: r) { items[item.id] = updated }
        lastRating = r
        stats.answered += 1
        if correct { stats.correct += 1 } else { stats.wrong += 1 }
        stats.ratings[r, default: 0] += 1
        var t = stats.byType[q.type] ?? (0, 0); t.total += 1; if correct { t.right += 1 }; stats.byType[q.type] = t
        queue.answer(correct: correct)
    }

    func next() {
        guard phase == .answered || phase == .asking else { return }
        if queue.finished { end() } else { loadCurrent() }
    }

    /// 斩 / 已掌握: retire the word for good.
    func retire() {
        guard let q = question, phase == .asking || phase == .answered else { return }
        _ = try? book.store?.retire(id: q.itemID)
        if phase == .asking { queue.retire() }
        else { queue.dropCurrentRequeue(q.itemID) }
        stats.retired += 1
        if queue.finished { end() } else { loadCurrent() }
    }
}
