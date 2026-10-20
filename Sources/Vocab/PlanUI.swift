import AppKit
import SwiftUI
import VocabCore

/// The 背诵计划 (persisted in UserDefaults) and the vocabulary-test history (in the wordbook DB).
@MainActor
final class PlanModel: ObservableObject {
    static let shared = PlanModel()
    @Published var plan: StudyPlan { didSet { if plan != oldValue { plan.save() } } }
    @Published private(set) var results: [VocabTestResult] = []
    @Published private(set) var lastBatch: RetireBatch?
    private var checkCache: (date: Date, words: Set<String>)?

    init() {
        var p = StudyPlan.load()
        if !p.configured, let old = UserDefaults.standard.object(forKey: ReviewSession.capKey) as? Int { p.dailyNew = old }
        plan = p
        reconcile()
        reloadResults()
    }

    var book: WordbookModel { .shared }

    /// Every exam list and every wordbook has a row; wordbooks start on, lists off.
    func reconcile() {
        var p = plan
        let books = book.books
        p.sources.removeAll { if case .book(let id) = $0.id { return !books.contains { $0.id == id } }; return false }
        for b in books where !p.sources.contains(where: { $0.id == .book(b.id) }) {
            p.sources.append(PlanSource(id: .book(b.id), enabled: true, ratio: 1))
        }
        for l in ExamList.allCases where !p.sources.contains(where: { $0.id == .list(l) }) {
            p.sources.append(PlanSource(id: .list(l), enabled: false, ratio: 1))
        }
        if p != plan { plan = p }
    }

    func reloadResults() {
        results = (try? book.store?.testResults()) ?? []
        lastBatch = (try? book.store?.latestBatch()) ?? nil
        checkCache = nil
    }

    func title(_ id: PlanSourceID) -> String {
        switch id {
        case .list(let l): return l.title
        case .book(let b): return book.books.first { $0.id == b }?.name ?? "生词本"
        }
    }

    func size(_ id: PlanSourceID) -> Int {
        switch id {
        case .list(let l): return WordLists.shared?.count(in: l) ?? 0
        case .book(let b): return book.items.filter { $0.bookID == b && SessionPlanner.isNew($0) }.count
        }
    }

    private func queues(liveItems: [WordItem]) -> [PlanMixer.Queue] {
        plan.sources.filter { $0.enabled && $0.ratio > 0 }.map { s in
            switch s.id {
            case .book(let b):
                return PlanMixer.Queue(id: s.id, ratio: s.ratio,
                                       words: liveItems.filter { $0.bookID == b && SessionPlanner.isNew($0) }.sorted { $0.added < $1.added }.map(\.word))
            case .list(let l):
                return PlanMixer.Queue(id: s.id, ratio: s.ratio, words: WordLists.shared?.words(in: l) ?? [])
            }
        }
    }

    func drawNew(count: Int, liveItems: [WordItem]) -> [(word: String, source: PlanSourceID)] {
        let exclude = (try? book.store?.planExclusions()) ?? []
        return PlanMixer.mix(queues(liveItems: liveItems), count: count, exclude: exclude, wordbookFirst: plan.wordbookFirst)
    }

    /// New words left across the enabled sources (each counted once).
    func remainingNew() -> Int {
        let exclude = (try? book.store?.planExclusions()) ?? []
        var all = Set<String>()
        for q in queues(liveItems: book.items) { for w in q.words { all.insert(w.lowercased()) } }
        return all.subtracting(exclude).count
    }

    /// Words in the middle bands of the latest test: asked 认识吗 when first served.
    var quickCheckWords: Set<String> {
        guard let r = results.first, let lists = WordLists.shared else { return [] }
        if let c = checkCache, c.date == r.date { return c.words }
        var s = Set<String>()
        for b in r.checkBands where b < r.bandRanges.count { s.formUnion(lists.lemmas(rank: r.bandRanges[b].lo, r.bandRanges[b].hi)) }
        checkCache = (r.date, s)
        return s
    }

    func save(_ r: VocabTestResult) { try? book.store?.saveTestResult(r); reloadResults() }

    /// Words in the bands the test marked as known.
    func knownWords(_ r: VocabTestResult) -> [String] {
        guard let lists = WordLists.shared else { return [] }
        return r.knownBands.filter { $0 < r.bandRanges.count }.flatMap { lists.lemmas(rank: r.bandRanges[$0].lo, r.bandRanges[$0].hi) }
    }

    func bulkRetire(_ r: VocabTestResult) {
        let ws = knownWords(r)
        guard !ws.isEmpty else { return }
        _ = try? book.store?.bulkRetire(ws, label: "词汇量测试 · 斩 \(ws.count) 个熟词")
        book.reload(); reloadResults()
    }

    func undoLastBatch() {
        guard let b = lastBatch else { return }
        try? book.store?.undoBatch(b.id)
        book.reload(); reloadResults()
    }
}

// MARK: - Plan sheet

struct PlanSheet: View {
    @ObservedObject var model = PlanModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var remaining = 0
    @State private var testing = false
    var onDone: () -> Void = {}

    private var enabledTotal: Double { model.plan.sources.filter(\.enabled).reduce(0) { $0 + $1.ratio } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("词书和生词本") {
                    ForEach($model.plan.sources) { $s in
                        HStack(spacing: 10) {
                            Toggle(isOn: $s.enabled) {
                                HStack(spacing: 4) {
                                    Image(systemName: s.id.isBook ? "book.closed" : "text.book.closed").foregroundStyle(.secondary)
                                    Text(model.title(s.id))
                                    Text("\(model.size(s.id))").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                                }
                            }
                            .toggleStyle(.checkbox)
                            Spacer()
                            Slider(value: $s.ratio, in: 0.1...5).frame(width: 110).disabled(!s.enabled)
                            Text(s.enabled && enabledTotal > 0 ? "\(Int((s.ratio / enabledTotal * 100).rounded()))%" : "–")
                                .monospacedDigit().foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
                        }
                    }
                    Toggle("生词本优先", isOn: $model.plan.wordbookFirst)
                    Text("新词按比例轮流抽取；某个来源抽完后，它的份额分给其他来源。每个词只学一次，在任何地方学过或斩过的都会跳过。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("每日") {
                    Stepper(value: $model.plan.dailyNew, in: 0...200, step: 5) { LabeledContent("新词上限", value: "\(model.plan.dailyNew)") }
                    Stepper(value: $model.plan.dailyReview, in: 10...1000, step: 10) { LabeledContent("复习上限", value: "\(model.plan.dailyReview)") }
                    Text("先复习，再学新词。今天的新词 = min(新词上限, 复习上限 − 到期数)。").font(.caption).foregroundStyle(.secondary)
                    Toggle("目标日期", isOn: Binding(get: { model.plan.targetDate != nil },
                                                  set: { model.plan.targetDate = $0 ? Calendar.current.date(byAdding: .month, value: 3, to: Date()) : nil }))
                    if let t = model.plan.targetDate {
                        DatePicker("完成日期", selection: Binding(get: { t }, set: { model.plan.targetDate = $0 }), in: Date()..., displayedComponents: .date)
                    }
                    projection
                }
                Section("词汇量测试") {
                    if let r = model.results.first {
                        LabeledContent("上次结果", value: "约 \(r.estimate) 词（\(r.low)–\(r.high)）")
                        LabeledContent("测试时间", value: r.date.formatted(date: .abbreviated, time: .shortened))
                        if model.results.count > 1 {
                            DisclosureGroup("历史记录") {
                                ForEach(Array(model.results.dropFirst().enumerated()), id: \.offset) { _, h in
                                    LabeledContent(h.date.formatted(date: .abbreviated, time: .omitted), value: "约 \(h.estimate) 词")
                                }
                            }
                        }
                    } else {
                        Text("先测一下词汇量：认识的常用词会被斩掉，不用再背。").foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(model.results.isEmpty ? "开始测试…" : "重新测试…") { testing = true }
                        Spacer()
                        if let b = model.lastBatch {
                            Button("撤销「\(b.label)」") { model.undoLastBatch(); refresh() }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("完成") { model.plan.configured = true; onDone(); dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 640)
        .onAppear { model.reconcile(); model.reloadResults(); refresh() }
        .onChange(of: model.plan.sources) { _, _ in refresh() }
        .sheet(isPresented: $testing, onDismiss: refresh) { VocabTestSheet() }
    }

    private func refresh() { remaining = model.remainingNew() }

    private var projection: some View {
        let p = PlanMath.projection(remaining: remaining, plan: model.plan)
        return VStack(alignment: .leading, spacing: 2) {
            if remaining == 0 { Text("所选来源没有新词了").foregroundStyle(.secondary) }
            else if let f = p.finish {
                Text("剩余 \(remaining) 个新词，按每天 \(model.plan.dailyNew) 个约需 \(p.days) 天，预计 \(f.formatted(date: .abbreviated, time: .omitted)) 学完")
            } else { Text("剩余 \(remaining) 个新词") }
            if let need = p.neededPerDay {
                Text(need <= model.plan.dailyNew ? "可以在目标日期前学完" : "要在目标日期前学完，每天需要约 \(need) 个新词")
                    .foregroundStyle(need <= model.plan.dailyNew ? Color.secondary : Color.orange)
            }
        }
        .font(.callout)
    }
}

// MARK: - Vocabulary test

struct VocabTestSheet: View {
    @ObservedObject var model = PlanModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var run: VocabTestRun?
    @State private var result: VocabTestResult?
    @State private var retired = false

    var body: some View {
        VStack(spacing: 0) {
            if let r = result { resultView(r) }
            else if let run, let item = run.current { question(run, item) }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(width: 480, height: 520)
        .onAppear(perform: start)
    }

    private func start() {
        guard let lists = WordLists.shared else { return }
        var rng = SystemRandomNumberGenerator()
        run = VocabTestRun(lists: lists, using: &rng)
        result = nil; retired = false
    }

    private func question(_ r: VocabTestRun, _ item: VocabTestItem) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("词汇量测试 · 第 \(r.round) 轮").font(.headline)
                Spacer()
                Text("\(r.answered + 1) / \(r.items.count)").monospacedDigit().foregroundStyle(.secondary)
                Button("取消") { dismiss() }
            }
            .padding(16)
            ProgressView(value: Double(r.answered), total: Double(max(1, r.items.count))).padding(.horizontal, 16)
            Spacer()
            Text(item.word).font(.system(size: 42, weight: .semibold, design: .serif))
            Text("知道这个词的意思吗？").foregroundStyle(.secondary).padding(.top, 8)
            Spacer()
            HStack(spacing: 16) {
                Button { answer(false) } label: { Text("不认识").frame(width: 120) }
                    .controlSize(.large).keyboardShortcut(.leftArrow, modifiers: [])
                Button { answer(true) } label: { Text("认识").frame(width: 120) }
                    .controlSize(.large).keyboardShortcut(.rightArrow, modifiers: []).buttonStyle(.borderedProminent)
            }
            HStack {
                Button("上一个") { run?.undo() }.disabled(r.answered == 0).keyboardShortcut(.delete, modifiers: [])
                Spacer()
                Text("← 不认识 · → 认识 · ⌫ 上一个").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(16)
        }
    }

    private func answer(_ known: Bool) {
        guard var r = run else { return }
        r.answer(known)
        if r.finished {
            var rng = SystemRandomNumberGenerator()
            if !(r.round == 1 && r.startRound2(using: &rng)) {
                let res = r.result()
                model.save(res); result = res
            }
        }
        run = r
    }

    private func resultView(_ r: VocabTestResult) -> some View {
        let known = model.knownWords(r).count
        return VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    Text("你的词汇量约").foregroundStyle(.secondary).padding(.top, 24)
                    Text("\(r.estimate)").font(.system(size: 48, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("可能在 \(r.low)–\(r.high) 之间").foregroundStyle(.secondary)
                    if r.falseAlarm > 0 {
                        Text("有 \(Int((r.falseAlarm * 100).rounded()))% 的假词被选了「认识」，结果已按此修正").font(.caption).foregroundStyle(.orange)
                    }
                    VStack(spacing: 6) {
                        ForEach(r.bands, id: \.band) { b in
                            HStack {
                                Text(r.bandRanges[b.band].title).font(.caption).monospacedDigit().frame(width: 92, alignment: .leading)
                                ProgressView(value: b.corrected)
                                Text("\(Int((b.corrected * 100).rounded()))%").font(.caption).monospacedDigit().frame(width: 36, alignment: .trailing)
                            }
                            .foregroundStyle(r.knownBands.contains(b.band) ? Color.primary : r.checkBands.contains(b.band) ? Color.primary : Color.secondary)
                        }
                    }
                    .padding(.horizontal, 30)
                    Text("认识率 ≥ 90% 的词频段视为已掌握；30%–90% 的词段第一次出现时先问一下「认识吗」。")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 30)
                }
            }
            Divider()
            HStack {
                Button("再测一次") { start() }
                Spacer()
                if known > 0 && !retired {
                    Button("斩掉 \(known) 个熟词") { model.bulkRetire(r); retired = true }
                        .help("作为一批操作，可在计划里撤销")
                } else if retired {
                    Button("撤销斩词") { model.undoLastBatch(); retired = false }
                }
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }
}
