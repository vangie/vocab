import Foundation

public enum QuestionType: String, CaseIterable, Sendable, Codable {
    case recall          // 看词想意思
    case meaningToWord   // 看意思选词
    case wordToMeaning   // 看词选意思
    case spelling        // 拼写
    case syllables       // 音节拆分 — retired: never generated (kept so old stats still decode)
    case roots           // 词根

    public var label: String {
        switch self {
        case .recall: "看词想意思"; case .meaningToWord: "看意思选词"; case .wordToMeaning: "看词选意思"
        case .spelling: "拼写"; case .syllables: "音节拆分"; case .roots: "词根词缀"
        }
    }
    public var isObjective: Bool { self != .recall }
}

public enum CardStage: Sendable { case new, learning, mature
    public init(_ s: ReviewState) {
        switch s.state {
        case .new: self = .new
        case .learning, .relearning: self = .learning
        case .review: self = (s.stability ?? 0) < 7 ? .learning : .mature
        }
    }
}

/// Objective answers → scheduler ratings.
public enum RatingMap {
    /// Seconds under which a correct answer counts as fast (Easy) and over which it counts as slow (Hard).
    public static func thresholds(_ t: QuestionType, length: Int) -> (fast: Double, slow: Double) {
        switch t {
        case .spelling: return (2.5 + 0.35 * Double(length), 8 + 0.8 * Double(length))
        case .meaningToWord, .wordToMeaning: return (3, 9)
        case .syllables, .roots: return (4, 12)
        case .recall: return (0, .infinity)
        }
    }

    /// wrong → Again (忘了), correct but slow → Hard (模糊), correct → Good (记得), fast → Easy (简单).
    public static func rating(correct: Bool, seconds: Double, type: QuestionType, length: Int) -> ReviewRating {
        guard correct else { return .forgot }
        let th = thresholds(type, length: length)
        if seconds <= th.fast { return .easy }
        if seconds >= th.slow { return .fuzzy }
        return .good
    }

    /// A spelling answered after using 提示 can at best count as 模糊.
    public static func capped(_ r: ReviewRating, hinted: Bool) -> ReviewRating {
        guard hinted, r == .good || r == .easy else { return r }
        return .fuzzy
    }
}

/// 提示 for 拼写: the first `shown` letters, the rest as blanks — "r e l _ _ _ _ _".
public enum SpellingHint {
    public static func mask(_ word: String, shown: Int) -> String {
        word.enumerated().map { i, c in i < shown || !c.isLetter ? String(c) : "_" }.joined(separator: " ")
    }
    /// Letters a hint may reveal (never the whole word: the last letter stays for the user).
    public static func maxHints(_ word: String) -> Int { max(0, word.count - 1) }
}

/// Picks the question type for a card. New and learning cards only get objective types; the
/// self-graded 看词想意思 is reserved for mature cards and kept rare (≤ `maxRecallShare`).
public enum QuestionPicker {
    public static let maxRecallShare = 0.15
    public static func weights(_ stage: CardStage) -> [QuestionType: Double] {
        switch stage {
        case .new: [.wordToMeaning: 3, .meaningToWord: 2]
        case .learning: [.meaningToWord: 2, .wordToMeaning: 1.5, .roots: 1.5, .spelling: 1.5]
        case .mature: [.spelling: 3, .meaningToWord: 1.5, .roots: 1, .recall: 0.9]
        }
    }
    /// Objective fallbacks when a card's stage weights have nothing available.
    static let fallback: [QuestionType] = [.wordToMeaning, .meaningToWord, .spelling, .roots]

    /// `available` lists the types this card can support (roots need a match, choices need distractors…).
    /// Avoids repeating the previous type so the session interleaves.
    public static func pick<R: RandomNumberGenerator>(stage: CardStage, available: Set<QuestionType>,
                                                       previous: QuestionType?, using rng: inout R) -> QuestionType {
        var w = weights(stage).filter { available.contains($0.key) && $0.key != .syllables }
        if w.count > 1, let p = previous { w[p] = nil }
        // Keep recall rare relative to what this card can actually be asked.
        if let r = w[.recall] {
            let others = w.filter { $0.key != .recall }.values.reduce(0, +)
            if others > 0 { w[.recall] = min(r, others * maxRecallShare / (1 - maxRecallShare)) }
        }
        if w.isEmpty {
            // Only a card with no meaning or distractors at all ends up self-graded.
            return fallback.first { available.contains($0) && $0 != previous } ?? fallback.first { available.contains($0) } ?? .recall
        }
        let total = w.values.reduce(0, +)
        var x = Double.random(in: 0..<total, using: &rng)
        for (t, v) in w.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if x < v { return t }
            x -= v
        }
        return w.keys.sorted { $0.rawValue < $1.rawValue }.last!
    }
}

/// Builds today's session: reviews first, then new words up to the daily cap.
public enum SessionPlanner {
    public static func plan(_ items: [WordItem], now: Date, newCap: Int, newIntroducedToday: Int) -> [WordItem] {
        let live = items.filter { !Scheduler.isMastered($0.review) }
        let reviews = live.filter { !isNew($0) && $0.review.due <= now }.sorted { $0.review.due < $1.review.due }
        let room = max(0, newCap - newIntroducedToday)
        let fresh = live.filter(isNew).sorted { $0.added < $1.added }.prefix(room)
        return reviews + fresh
    }
    public static func isNew(_ i: WordItem) -> Bool { i.review.state == .new }
}

/// The in-session queue: a wrong answer comes back a few cards later.
public struct ReviewQueue: Sendable, Codable, Equatable {
    public private(set) var pending: [Int64]
    public private(set) var done: Set<Int64> = []
    public private(set) var wrong: [Int64: Int] = [:]
    public let total: Int
    public static let requeueGap = 3

    public init(ids: [Int64]) { pending = ids; total = ids.count }
    public var current: Int64? { pending.first }
    public var finished: Bool { pending.isEmpty }
    public var progress: Double { total == 0 ? 1 : Double(done.count) / Double(total) }

    public mutating func answer(correct: Bool) {
        guard let id = pending.first else { return }
        pending.removeFirst()
        if correct { done.insert(id) }
        else { wrong[id, default: 0] += 1; pending.insert(id, at: min(pending.count, Self.requeueGap)) }
    }
    /// 斩 after the card was already answered: forget any pending repeat of it.
    public mutating func dropCurrentRequeue(_ id: Int64) {
        pending.removeAll { $0 == id }; done.insert(id)
    }
    /// 斩: drop a card from the session for good.
    public mutating func retire() {
        guard let id = pending.first else { return }
        pending.removeFirst(); done.insert(id)
    }
}

/// Letter-level spelling feedback.
public struct LetterMark: Hashable, Sendable {
    public enum Kind: Sendable { case correct, wrong, missing, extra }
    /// What the user's line shows: the typed letter (correct / wrong / extra), or for `missing`
    /// the left-out answer letter (drawn as a blank placeholder).
    public let char: Character
    public let kind: Kind
    /// The answer letter this position aligns to (nil for `extra`).
    public let expected: Character?
    public init(char: Character, kind: Kind, expected: Character? = nil) { self.char = char; self.kind = kind; self.expected = expected }
}

public enum SpellingCheck {
    public static func isCorrect(_ typed: String, _ answer: String) -> Bool {
        typed.trimmingCharacters(in: .whitespaces).lowercased() == answer.lowercased()
    }

    /// Align the user's input against the answer (Levenshtein backtrace), in reading order:
    /// correct / wrong carry the typed letter (wrong = substitution), missing = answer letter left out,
    /// extra = typed letter not in the answer. Dropping `missing` reproduces exactly what was typed.
    public static func diff(typed: String, answer: String) -> [LetterMark] {
        let raw = Array(typed), a = Array(typed.lowercased()), b = Array(answer)
        let bl = b.map { Character($0.lowercased()) }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        if !a.isEmpty && !b.isEmpty {
            for i in 1...a.count { for j in 1...b.count {
                d[i][j] = min(d[i-1][j] + 1, d[i][j-1] + 1, d[i-1][j-1] + (a[i-1] == bl[j-1] ? 0 : 1))
            } }
        }
        var i = a.count, j = b.count; var out: [LetterMark] = []
        while i > 0 || j > 0 {
            if i > 0, j > 0, d[i][j] == d[i-1][j-1] + (a[i-1] == bl[j-1] ? 0 : 1) {
                out.append(LetterMark(char: raw[i-1], kind: a[i-1] == bl[j-1] ? .correct : .wrong, expected: b[j-1])); i -= 1; j -= 1
            } else if j > 0, d[i][j] == d[i][j-1] + 1 {
                out.append(LetterMark(char: b[j-1], kind: .missing, expected: b[j-1])); j -= 1
            } else {
                out.append(LetterMark(char: raw[i-1], kind: .extra)); i -= 1
            }
        }
        return out.reversed()
    }
}

public enum ContextHint {
    /// The sentence where the word was looked up, with the word (and its inflections) blanked.
    public static func blank(_ sentence: String, word: String, mask: String = "＿＿＿") -> String {
        var stem = word
        if stem.count > 4, let l = stem.last, "ey".contains(l) { stem = String(stem.dropLast()) }
        let pat = "\\b" + NSRegularExpression.escapedPattern(for: stem) + "[a-z]*"
        guard let re = try? NSRegularExpression(pattern: pat, options: .caseInsensitive) else { return sentence }
        return re.stringByReplacingMatches(in: sentence, range: NSRange(location: 0, length: (sentence as NSString).length), withTemplate: mask)
    }
}

/// Per-session tallies. `record` one answer; `unrecord` takes it back (斩 right after answering
/// replaces that answer, so it isn't counted twice).
public struct SessionStats: Codable {
    enum CodingKeys: String, CodingKey { case answered, correct, wrong, retired, ratings, byType, started }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        answered = try c.decode(Int.self, forKey: .answered); correct = try c.decode(Int.self, forKey: .correct)
        wrong = try c.decode(Int.self, forKey: .wrong); retired = try c.decode(Int.self, forKey: .retired)
        started = try c.decode(Date.self, forKey: .started)
        for (k, v) in try c.decode([String: Int].self, forKey: .ratings) { if let i = Int(k), let r = ReviewRating(rawValue: i) { ratings[r] = v } }
        for (k, v) in try c.decode([String: [Int]].self, forKey: .byType) where v.count == 2 { if let t = QuestionType(rawValue: k) { byType[t] = (v[0], v[1]) } }
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(answered, forKey: .answered); try c.encode(correct, forKey: .correct)
        try c.encode(wrong, forKey: .wrong); try c.encode(retired, forKey: .retired); try c.encode(started, forKey: .started)
        try c.encode(Dictionary(uniqueKeysWithValues: ratings.map { (String($0.key.rawValue), $0.value) }), forKey: .ratings)
        try c.encode(Dictionary(uniqueKeysWithValues: byType.map { ($0.key.rawValue, [$0.value.right, $0.value.total]) }), forKey: .byType)
    }

    public var answered = 0, correct = 0, wrong = 0, retired = 0
    public var ratings: [ReviewRating: Int] = [:]
    public var byType: [QuestionType: (right: Int, total: Int)] = [:]
    public var started = Date()
    public init() {}

    public mutating func record(_ r: ReviewRating, correct ok: Bool, type: QuestionType) {
        answered += 1
        if ok { correct += 1 } else { wrong += 1 }
        ratings[r, default: 0] += 1
        var t = byType[type] ?? (0, 0); t.total += 1; if ok { t.right += 1 }; byType[type] = t
    }

    public mutating func unrecord(_ r: ReviewRating, correct ok: Bool, type: QuestionType) {
        answered = max(0, answered - 1)
        if ok { correct = max(0, correct - 1) } else { wrong = max(0, wrong - 1) }
        if let n = ratings[r] { ratings[r] = n > 1 ? n - 1 : nil }
        if var t = byType[type] {
            t.total -= 1; if ok { t.right -= 1 }
            byType[type] = t.total > 0 ? t : nil
        }
    }
}


/// An unfinished 记词 round, saved after every step so a relaunch can resume it.
/// Ratings, 斩 and counters are written as they happen elsewhere; this only keeps the round itself.
public struct SessionSnapshot: Codable {
    /// A list word not yet written to the wordbook (negative session id).
    public struct Virtual: Codable, Equatable {
        public var id: Int64, word: String, definition: String, list: ExamList
        public init(id: Int64, word: String, definition: String, list: ExamList) { self.id = id; self.word = word; self.definition = definition; self.list = list }
    }
    public var date: Date
    public var queue: ReviewQueue
    public var stats: SessionStats
    public var virtuals: [Virtual]
    public var realID: [Int64: Int64]
    public var newSource: [Int64: ExamList]
    public var quickCheck: Set<Int64>
    public var answeredOnce: Set<Int64>
    public var firstDone: Set<Int64>
    public init(date: Date, queue: ReviewQueue, stats: SessionStats, virtuals: [Virtual], realID: [Int64: Int64],
                newSource: [Int64: ExamList], quickCheck: Set<Int64>, answeredOnce: Set<Int64>, firstDone: Set<Int64>) {
        self.date = date; self.queue = queue; self.stats = stats; self.virtuals = virtuals; self.realID = realID
        self.newSource = newSource; self.quickCheck = quickCheck; self.answeredOnce = answeredOnce; self.firstDone = firstDone
    }

    /// Resumable: same calendar day and cards left.
    public func resumable(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        !queue.finished && StudyDay.same(date, now, calendar)
    }

    public static let defaultsKey = "reviewSessionSnapshot"
    public static func load(_ d: UserDefaults = .standard) -> SessionSnapshot? {
        d.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(SessionSnapshot.self, from: $0) }
    }
    public func save(_ d: UserDefaults = .standard) { d.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey) }
    public static func clear(_ d: UserDefaults = .standard) { d.removeObject(forKey: defaultsKey) }
}
