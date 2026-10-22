import Foundation

public struct ReviewQuestion: Identifiable, Sendable {
    public let id = UUID()
    public let type: QuestionType
    public let itemID: Int64
    public let word: String
    public let gloss: Gloss
    /// Options for choice questions (already shuffled); `correctIndex` points at the right one.
    public var options: [String] = []
    /// What to show next to each option once answered (百词斩 shows every option's meaning).
    public var optionNotes: [String] = []
    public var correctIndex: Int = 0
    public var syllables: [String] = []
    public var morpheme: MorphemeMatch?
    public var hint: String?
    public var audio: URL?
    /// The English word behind each option (choice questions with words), for IPA/pronunciation.
    public var optionWords: [String] = []

    /// The right option, or one whose word is just another spelling of the answer (realise/realize).
    public func isCorrectChoice(_ i: Int) -> Bool {
        if i == correctIndex { return true }
        guard optionWords.indices.contains(i), !optionWords[i].isEmpty else { return false }
        return Distractors.isSpellingVariant(optionWords[i], word)
    }
}

/// Everything a word needs for any question type, computed once per session.
public struct WordMaterials: Sendable {
    public var gloss = Gloss()
    public var syllables: [String] = []
    public var syllablesFromDictionary = false
    public var morphemes: [MorphemeMatch] = []
    public var distractors: [(word: String, gloss: Gloss)] = []
    public var audio: URL?

    public var available: Set<QuestionType> {
        var s: Set<QuestionType> = [.recall]
        let haveMeaning = !gloss.isEmpty
        if haveMeaning { s.insert(.spelling) }
        if haveMeaning && distractors.count >= 3 { s.formUnion([.meaningToWord, .wordToMeaning]) }
        // 音节拆分 is no longer asked.
        if !morphemes.isEmpty { s.insert(.roots) }
        return s
    }
}

public final class QuestionFactory: @unchecked Sendable {
    let service: DictionaryService
    let dicts: [DictionaryInfo]
    let thesaurus: DictionaryInfo?
    let book: [String]
    private var cache: [String: WordMaterials] = [:]
    /// Short Chinese meaning when no system dictionary has one (ECDICT extract).
    public var fallbackChinese: (@Sendable (String) -> String?)? = { WordLists.shared?.shortChinese($0) }
    private let lock = NSLock()

    public init(service: DictionaryService = .shared, dicts: [DictionaryInfo], thesaurus: DictionaryInfo?, book: [String]) {
        self.service = service; self.dicts = dicts.filter { !$0.isNetwork }; self.thesaurus = thesaurus; self.book = book   // no Wikipedia: DCS network search hangs
    }

    static func normalize(_ headword: String) -> String {
        headword.filter { !Hyphenation.dots.contains($0) && !$0.isNumber }.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The word's gloss, tidied; a cross-reference ("labour 的美式拼法", "the past tense of lie") is
    /// followed to the base word's real meaning, with the reference kept as a feedback-only note.
    /// An unresolvable reference leaves the meaning empty, so no meaning-choice question is made.
    public func gloss(_ word: String) -> Gloss { Self.resolve(word, raw: rawGloss) }

    static func resolve(_ word: String, depth: Int = 0, raw: (String) -> Gloss) -> Gloss {
        var g = raw(word)
        g.chinese = GlossExtractor.tidy(g.chinese); g.english = GlossExtractor.tidy(g.english)
        let zhRef = GlossExtractor.crossReference(g.chinese), enRef = GlossExtractor.crossReference(g.english)
        guard let ref = zhRef ?? enRef else { return g }
        let b = depth < 2 && ref.base.lowercased() != word.lowercased() ? resolve(ref.base, depth: depth + 1, raw: raw) : Gloss()
        var out = g
        out.note = zhRef != nil ? g.chinese : g.english
        if zhRef != nil { out.chinese = b.chinese }
        if enRef != nil { out.english = b.english }
        return out
    }

    private func rawGloss(_ word: String) -> Gloss {
        let entries = service.lookup(word, in: dicts, maxPerDictionary: 2)
            .filter { Self.normalize($0.headword) == word.lowercased() }
        var g = Gloss()
        for e in entries {
            if g.chinese == nil { g.chinese = GlossExtractor.chinese(fromHTML: e.html) }
            if g.english == nil { g.english = GlossExtractor.english(fromHTML: e.html) }
            if g.chinese != nil && g.english != nil { break }
        }
        if g.chinese == nil || GlossExtractor.crossReference(g.chinese) != nil,
           let z = fallbackChinese?(word.lowercased()), GlossExtractor.crossReference(z) == nil { g.chinese = z }
        else if g.chinese == nil, let z = fallbackChinese?(word.lowercased()) { g.chinese = z }
        return g
    }

    /// Ranked confusable words with their glosses, near-synonyms removed.
    public func distractors(for word: String, gloss target: Gloss, want: Int = 3) -> [(word: String, gloss: Gloss)] {
        let w = word.lowercased()
        var cands = Distractors.variants(w).filter { service.hasEntry($0, in: dicts) }
        if w.count >= 3 {
            cands += service.headwords(String(w.prefix(3)), method: 1, in: dicts, maxPerDictionary: 400)
            if w.count >= 6 { cands += service.headwords(String(w.prefix(2)) + String(w.dropFirst(3).prefix(2)), method: 1, in: dicts, maxPerDictionary: 100) }
        }
        cands += book + Confusables.partners(of: w)
        var syn = Set<String>()
        if let t = thesaurus { for e in service.lookup(word, in: [t], maxPerDictionary: 3) { syn.formUnion(Distractors.thesaurusWords(e.plainText)) } }
        var out: [(String, Gloss)] = []
        for c in Distractors.rank(target: word, candidates: cands, synonyms: syn, book: Set(book), limit: 14) {
            let g = gloss(c.word)
            guard !g.isEmpty, g.note == nil, !g.short.hasPrefix("/"), !g.short.contains("拼法"), !g.short.contains("过去式"), !g.short.contains("过去分词"), !g.short.contains("复数"), !g.short.contains("现在分词") else { continue }
            guard Distractors.keep(target: word, candidate: c.word, targetGloss: target, candidateGloss: g, synonyms: syn) else { continue }
            if out.contains(where: { $0.1.short == g.short || GlossExtractor.nearIdentical($0.1.chinese, g.chinese) }) { continue }
            out.append((c.word, g))
            if out.count == want { break }
        }
        return out
    }

    public func materials(for word: String) -> WordMaterials {
        lock.lock(); if let m = cache[word] { lock.unlock(); return m }; lock.unlock()
        var m = WordMaterials()
        m.gloss = gloss(word)
        let entries = service.lookup(word, in: dicts, maxPerDictionary: 1)
        for e in entries {
            if let s = Hyphenation.fromDictionaryText(e.plainText, word: word) { m.syllables = s; m.syllablesFromDictionary = true; break }
        }
        if m.syllables.isEmpty { m.syllables = Hyphenation.system(word) }
        m.morphemes = RootTable.matches(word)
        m.distractors = distractors(for: word, gloss: m.gloss)
        // Exact word only, never the lemma's recording; nil means the session speaks it with TTS.
        m.audio = Phonetics.lookup(word, in: dicts, service: service).audio
        lock.lock(); cache[word] = m; lock.unlock()
        return m
    }

    static func pronunciation(in entries: [DictionaryEntry]) -> URL? {
        for pref in ["ameProns", "Prons", ""] {
            for e in entries {
                guard let dir = e.resourceDirectory else { continue }
                for a in EntryHTML.audioReferences(in: e.html) where !a.contains("exaProns") && (pref.isEmpty || a.contains(pref)) {
                    let u = dir.appendingPathComponent(a)
                    if FileManager.default.fileExists(atPath: u.path) { return u }
                }
            }
        }
        return nil
    }

    public func make<R: RandomNumberGenerator>(_ item: WordItem, type: QuestionType, using rng: inout R) -> ReviewQuestion {
        let m = materials(for: item.word)
        var q = ReviewQuestion(type: type, itemID: item.id, word: item.word, gloss: m.gloss)
        q.audio = m.audio
        q.syllables = m.syllables
        q.morpheme = m.morphemes.first
        if let c = item.context, !c.isEmpty { q.hint = ContextHint.blank(c, word: item.word) }
        func shuffle(_ opts: [(String, String)]) {
            let order = Array(opts.indices).shuffled(using: &rng)
            q.options = order.map { opts[$0].0 }; q.optionNotes = order.map { opts[$0].1 }
            q.correctIndex = order.firstIndex(of: 0) ?? 0
        }
        switch type {
        case .wordToMeaning:
            // Confusables can share a short Chinese gloss (affect/effect: 影响); then show English so options differ.
            let all = [m.gloss] + m.distractors.map(\.gloss)
            let shorts = all.map(\.short)
            let useEnglish = Set(shorts).count < shorts.count && all.allSatisfy { $0.english != nil }
            func text(_ g: Gloss) -> String { useEnglish ? GlossExtractor.clip(g.english!, 80) : g.short }
            shuffle([(text(m.gloss), item.word)] + m.distractors.map { (text($0.gloss), $0.word) })
            q.optionWords = q.optionNotes
        case .meaningToWord:
            shuffle([(item.word, m.gloss.short)] + m.distractors.map { ($0.word, $0.gloss.short) })
            q.optionWords = q.options
        case .syllables:
            let opts = Hyphenation.options(correct: m.syllables) ?? [m.syllables]
            shuffle(opts.enumerated().map { ($0.element.joined(separator: " · "), $0.offset == 0 ? "正确" : "") })
        case .roots:
            if let mm = q.morpheme {
                let others = RootTable.all.filter { $0.kind == mm.morpheme.kind && $0.meaning != mm.morpheme.meaning }
                    .shuffled(using: &rng).prefix(3)
                shuffle([(mm.morpheme.meaning, mm.morpheme.display)] + others.map { ($0.meaning, $0.display) })
            }
        case .recall, .spelling: break
        }
        return q
    }
}
