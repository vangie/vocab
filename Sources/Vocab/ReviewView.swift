import AppKit
import SwiftUI
import VocabCore

/// 背单词: mixed question types, keyboard first (1–4 pick, space flips, ↩ submits/continues).
struct ReviewView: View {
    @ObservedObject var session = ReviewSession.shared
    @ObservedObject var state = AppState.shared
    @EnvironmentObject var book: WordbookModel

    var body: some View {
        Group {
            switch session.phase {
            case .idle: StartScreen(session: session)
            case .summary: FitHeight(levels: [.normal]) { _ in SummaryScreen(session: session) }
            case .loading: if session.question == nil { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) } else { QuestionScreen(session: session) }
            case .asking, .answered: QuestionScreen(session: session)
            case .check: FitHeight(levels: [.normal]) { _ in CheckScreen(session: session) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { session.refreshPreview() }
        .onChange(of: PlanModel.shared.plan) { _, _ in session.refreshPreview() }
    }
}

private struct StartScreen: View {
    @ObservedObject var session: ReviewSession
    @ObservedObject var plan = PlanModel.shared
    var body: some View {
        VStack(spacing: 0) {
            if !plan.plan.configured {
                // First visit: an inline prompt instead of a popup.
                HStack(spacing: 10) {
                    Image(systemName: "calendar").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("还没有设置背诵计划：选词书、定目标，先测一下词汇量可以跳过认识的词。")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("设置计划…") { AppState.shared.openPlan() }.buttonStyle(.borderedProminent)
                    Button("以后再说") { plan.plan.configured = true }.buttonStyle(.borderless)
                }
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .padding([.horizontal, .top], 16)
            }
            // Corner tools: a row of its own (not an overlay), so it never covers the rings.
            HStack { Spacer(); TestLinks() }
                .padding(.horizontal, 14).padding(.top, 10)
            FitHeight(levels: [.normal, .compact]) { d in content.environment(\.quizDensity, d) }
        }
    }

    private var content: some View {
        VStack(spacing: 14) {
            Spacer()
            let p = session.preview
            if plan.plan.configured {
                PlanDashboard(session: session, plan: plan.plan)
                VStack(spacing: 10) {
                    if p.reviews + p.new == 0 {
                        Label("今天的任务完成了", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.title3.weight(.medium))
                        Button { session.start(extraNew: ReviewSession.extraGroupSize) } label: {
                            Text("再学一组").frame(minWidth: 120)
                        }
                        .controlSize(.large).buttonBorderShape(.capsule)
                        .help("再学 \(ReviewSession.extraGroupSize) 个新词（含到期复习）")
                    } else {
                        Button { session.start() } label: { Text("开始").font(.title2.weight(.semibold)).frame(minWidth: 200, minHeight: 48) }
                            .keyboardShortcut(.defaultAction).controlSize(.large)
                            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                        Text("1–4 选择 · 空格 翻面 · ↩ 提交 / 继续 · ⌘K 斩").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 18)   // + the stack's 14 pt = 32 pt below the pills
            } else if p.reviews + p.new == 0 {
                Image(systemName: "checkmark.circle").font(.system(size: 46, weight: .light)).foregroundStyle(.green)
                Text("今天没有要复习的单词").font(.title3)
                Text("新词上限 \(ReviewSession.dailyNewCap) 个，今天已学 \(ReviewSession.introducedToday) 个").foregroundStyle(.secondary)
            } else {
                Image(systemName: "rectangle.stack").font(.system(size: 42, weight: .light)).foregroundStyle(.secondary)
                Text("今日背单词").font(.title2.weight(.semibold))
                HStack(spacing: 28) {
                    Stat(value: p.reviews, label: "待复习")
                    Stat(value: p.new, label: "新词")
                }
                Button { session.start() } label: { Text("开始").font(.title3.weight(.semibold)).frame(minWidth: 160, minHeight: 40) }
                    .keyboardShortcut(.defaultAction).controlSize(.extraLarge)
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).padding(.top, 6)
                Text("1–4 选择 · 空格 翻面 · ↩ 提交 / 继续 · ⌘K 斩").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }
}

/// 认识吗: a middle-band word from the vocabulary test, before it is learned.
private struct CheckScreen: View {
    @ObservedObject var session: ReviewSession
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text(session.checkWord ?? "").font(.system(size: 40, weight: .semibold, design: .serif))
            Text("认识这个词吗？").foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button { session.answerCheck(known: false) } label: { Text("不认识，学一下").frame(width: 130) }
                    .controlSize(.large).keyboardShortcut(.leftArrow, modifiers: [])
                Button { session.answerCheck(known: true) } label: { Text("认识，斩").frame(width: 130) }
                    .controlSize(.large).keyboardShortcut(.rightArrow, modifiers: []).buttonStyle(.borderedProminent)
            }
            Text("← 不认识 · → 认识").font(.caption).foregroundStyle(.tertiary)
            Spacer()
        }
    }
}

private struct Stat: View {
    let value: Int; let label: String
    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct QuestionScreen: View {
    @ObservedObject var session: ReviewSession

    var body: some View {
        VStack(spacing: 0) {
            // Header and the 继续 footer stay pinned; only the question scrolls when the window is short.
            header
            // Fit the window: normal → compact → compact with 2×2 options; scroll only as a last resort.
            FitHeight(levels: [.normal, .compact, .grid]) { d in middle(d) }
            footer
        }
    }

    private func middle(_ d: QuizDensity) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: d == .normal ? 16 : 6)
            if let q = session.question {
                content(q, d).frame(maxWidth: d == .grid ? 640 : 560).padding(.horizontal, d == .normal ? 32 : 20)
                    .id(q.id)
                    .contentShape(Rectangle())
                    .onHover { session.autoPaused = $0 }
            }
            Spacer(minLength: d == .normal ? 16 : 6)
        }
        .environment(\.quizDensity, d)
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                // Top-left, mirroring 斩 top-right; far from 继续 (bottom-right).
                Button { session.end() } label: { Label("结束", systemImage: "xmark") }
                    .help("结束本轮，查看小结（Esc）")
                    .keyboardShortcut(.cancelAction)
                if let q = session.question {
                    Text(q.type.label).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }
                Spacer()
                Text("\(session.queue.done.count) / \(session.queue.total)").monospacedDigit().foregroundStyle(.secondary)
                Button { session.retire() } label: { Label { Text("斩") } icon: { CleaverIcon.swiftUI } }
                    .help("已掌握：不再复习这个词（⌘K）")
                    .keyboardShortcut("k", modifiers: .command)
            }
            ProgressView(value: session.queue.progress).progressViewStyle(.linear)
        }
        .padding(.horizontal, 20).padding(.top, 14)
    }

    @ViewBuilder private func content(_ q: ReviewQuestion, _ density: QuizDensity) -> some View {
        VStack(spacing: density == .normal ? 18 : 10) {
            switch q.type {
            case .recall: RecallCard(session: session, q: q)
            case .wordToMeaning:
                WordTitle(q: q, session: session)
                Options(session: session, q: q)
            case .meaningToWord:
                MeaningPrompt(q: q)
                Options(session: session, q: q)
            case .spelling: SpellingCard(session: session, q: q)
            case .syllables:
                Text("选择正确的音节划分").foregroundStyle(.secondary)
                WordTitle(q: q, session: session)
                Options(session: session, q: q, monospaced: true)
            case .roots:
                RootPrompt(q: q, session: session)
                Options(session: session, q: q)
            }
            if let h = q.hint, q.type != .wordToMeaning {
                Text(h).italic().foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(density == .normal ? 3 : 2)
                    .font(.callout).padding(.top, 4)
            }
            if session.phase == .answered { AnswerBanner(session: session, q: q) }
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            Spacer()
            if session.phase == .answered {
                Button { session.next() } label: {
                    HStack(spacing: 6) { Text("继续"); Text("↩").foregroundStyle(.secondary) }
                }
                .keyboardShortcut(.defaultAction).controlSize(.large).help("继续（↩ 或空格）")
                .overlay(alignment: .bottom) {
                    if let p = session.autoProgress {
                        // Thin countdown bar under the button; pauses while the pointer is over the answer.
                        GeometryReader { g in
                            Capsule().fill(.quaternary).overlay(alignment: .leading) {
                                Capsule().fill(Color.accentColor.opacity(0.7)).frame(width: g.size.width * p)
                            }
                        }
                        .frame(height: 2).offset(y: 7)
                        .accessibilityLabel("即将自动下一题")
                    }
                }
                // Space also continues.
                Button("") { session.next() }.keyboardShortcut(.space, modifiers: []).hidden().frame(width: 0)
            }
        }
        .frame(height: 50).padding(.horizontal, 20).padding(.bottom, 16)
    }
}

private struct WordTitle: View {
    let q: ReviewQuestion; let session: ReviewSession
    @Environment(\.quizDensity) private var d
    var body: some View {
        HStack(spacing: 10) {
            Text(q.word).font(.system(size: d.headword, weight: .semibold, design: .serif)).textSelection(.enabled)
            SpeakButton(session: session)
        }
    }
}

private struct SpeakButton: View {
    let session: ReviewSession
    var body: some View {
        Button { session.speak() } label: { Image(systemName: "speaker.wave.2") }
            .buttonStyle(.borderless).help("朗读（⌘R）")
            .keyboardShortcut("r", modifiers: .command)
    }
}

private struct MeaningPrompt: View {
    let q: ReviewQuestion
    @Environment(\.quizDensity) private var d
    var body: some View {
        VStack(spacing: 8) {
            if let c = q.gloss.chinese { Text(c).font(.title2.weight(.semibold)).multilineTextAlignment(.center) }
            if let e = q.gloss.english {
                Text(ContextHint.blank(e, word: q.word)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .lineLimit(d == .normal ? nil : 3)
            }
        }
    }
}

private struct RootPrompt: View {
    let q: ReviewQuestion; let session: ReviewSession
    @Environment(\.quizDensity) private var d
    var body: some View {
        VStack(spacing: 8) {
            if let m = q.morpheme {
                HStack(spacing: 0) {
                    let w = Array(q.word)
                    Text(String(w[0..<m.range.lowerBound]))
                    Text(String(w[m.range])).foregroundStyle(Color.accentColor).underline()
                    Text(String(w[m.range.upperBound...]))
                }
                .font(.system(size: d.headword, weight: .semibold, design: .serif))
                Text("\(m.morpheme.kind == .root ? "词根" : m.morpheme.kind == .prefix ? "前缀" : "后缀") \(m.morpheme.display) 的意思是？")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct Options: View {
    @ObservedObject var session: ReviewSession
    let q: ReviewQuestion
    var monospaced = false
    @Environment(\.quizDensity) private var d

    var body: some View {
        if d == .grid {
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(Array(stride(from: 0, to: q.options.count, by: 2)), id: \.self) { r in
                    GridRow {
                        option(r, q.options[r])
                        if r + 1 < q.options.count { option(r + 1, q.options[r + 1]) } else { Color.clear }
                    }
                }
            }
        } else {
            VStack(spacing: d == .normal ? 8 : 5) {
                ForEach(Array(q.options.enumerated()), id: \.offset) { i, opt in option(i, opt) }
            }
        }
    }

    @ViewBuilder private func option(_ i: Int, _ opt: String) -> some View {
                Button { session.choose(i) } label: {
                    HStack(spacing: 12) {
                        Text("\(i + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(opt).font(monospaced ? .system(.title3, design: .monospaced) : .body)
                                .multilineTextAlignment(.leading).lineLimit(2)
                            if session.phase == .answered, !q.optionNotes[i].isEmpty, q.type != .syllables {
                                Text(q.optionNotes[i]).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if session.phase == .answered {
                            if i == q.correctIndex { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                            else if i == session.chosen { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
                        }
                    }
                    .padding(.horizontal, d == .normal ? 14 : 10).padding(.vertical, d == .normal ? 10 : 5)
                    .frame(maxWidth: .infinity, maxHeight: d == .grid ? .infinity : nil, alignment: .leading)
                    .background(background(i), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator.opacity(0.6)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(session.phase != .asking)
                .modifier(NumberKey(n: i + 1, active: session.phase == .asking))
    }

    private func background(_ i: Int) -> some ShapeStyle {
        guard session.phase == .answered else { return AnyShapeStyle(.background.secondary) }
        if i == q.correctIndex { return AnyShapeStyle(Color.green.opacity(0.14)) }
        if i == session.chosen { return AnyShapeStyle(Color.red.opacity(0.14)) }
        return AnyShapeStyle(.background.secondary)
    }
}

private struct NumberKey: ViewModifier {
    let n: Int; let active: Bool
    func body(content: Content) -> some View {
        if active { content.keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: []) } else { content }
    }
}

private struct RecallCard: View {
    @ObservedObject var session: ReviewSession
    let q: ReviewQuestion
    var body: some View {
        VStack(spacing: 16) {
            WordTitle(q: q, session: session)
            if q.syllables.count > 1 { Text(q.syllables.joined(separator: "·")).foregroundStyle(.tertiary) }
            if session.revealed {
                Divider().frame(maxWidth: 240)
                MeaningPrompt(q: q)
                HStack(spacing: 10) {
                    // Must pick one (no skip): 忘了 · 模糊 · 记得.
                    ForEach([ReviewRating.forgot, .fuzzy, .good], id: \.self) { r in
                        Button { session.selfRate(r) } label: {
                            VStack(spacing: 1) { Text(r.label); Text("\(r.rawValue)").font(.caption2).foregroundStyle(.secondary) }
                                .frame(minWidth: 56)
                        }
                        .controlSize(.large)
                        .keyboardShortcut(KeyEquivalent(Character("\(r.rawValue)")), modifiers: [])
                    }
                }
                .padding(.top, 6)
            } else {
                Text("想一想它的意思").foregroundStyle(.secondary)
                Button("显示释义") { session.flip() }
                    .keyboardShortcut(.space, modifiers: []).controlSize(.large)
                Text("空格").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct SpellingCard: View {
    @ObservedObject var session: ReviewSession
    let q: ReviewQuestion
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 14) {
            Button { session.speak() } label: { Image(systemName: "speaker.wave.2.fill").font(.system(size: 28)) }
                .buttonStyle(.borderless).help("再听一遍（⌘R）").keyboardShortcut("r", modifiers: .command)
            MeaningPrompt(q: q)
            if session.phase == .answered {
                Letters(marks: session.marks).padding(.top, 4)
                if !session.lastCorrect { Text(q.word).font(.system(size: 26, weight: .semibold, design: .serif)) }
            } else {
                TextField("拼写这个单词，↩ 提交", text: $session.typed)
                    .textFieldStyle(.roundedBorder).font(.system(size: 22, design: .serif))
                    .multilineTextAlignment(.center).frame(maxWidth: 320)
                    .autocorrectionDisabled().focused($focused)
                    .onSubmit { session.submitSpelling() }
                    .onAppear { DispatchQueue.main.async { focused = true } }
            }
        }
    }
}

private struct Letters: View {
    let marks: [LetterMark]
    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(marks.enumerated()), id: \.offset) { _, m in
                Text(String(m.char))
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color(m.kind))
                    .strikethrough(m.kind == .extra)
                    .underline(m.kind == .missing)
                    .opacity(m.kind == .missing ? 0.75 : 1)
            }
        }
        .help("绿色 = 正确 · 红色 = 写错 · 下划线 = 漏写 · 删除线 = 多写")
    }
    private func color(_ k: LetterMark.Kind) -> Color {
        switch k { case .correct: .green; case .wrong: .red; case .missing: .orange; case .extra: .red }
    }
}

private struct AnswerBanner: View {
    @ObservedObject var session: ReviewSession
    let q: ReviewQuestion
    var body: some View {
        VStack(spacing: 6) {
            Label(session.lastCorrect ? "答对了" : "答错了，稍后再来一次",
                  systemImage: session.lastCorrect ? "checkmark.circle.fill" : "arrow.uturn.backward.circle.fill")
                .foregroundStyle(session.lastCorrect ? .green : .orange).font(.headline)
            HStack(spacing: 6) {
                Text(q.word).fontWeight(.semibold)
                if q.syllables.count > 1 { Text(q.syllables.joined(separator: "·")).foregroundStyle(.secondary) }
                Text(q.gloss.short).foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.callout)
            if let m = q.morpheme, q.type == .roots {
                Text("\(m.morpheme.display)：\(m.morpheme.meaning)（\(m.morpheme.gloss)）").font(.callout).foregroundStyle(.secondary)
            }
            if let r = session.lastRating { Text("评分：\(r.label)").font(.caption).foregroundStyle(.tertiary) }
        }
        .padding(.top, 6)
    }
}

private struct SummaryScreen: View {
    @ObservedObject var session: ReviewSession
    var body: some View {
        let s = session.stats
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "flag.checkered").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text(session.queue.finished ? "本轮完成" : "本轮小结").font(.title2.weight(.semibold))
            HStack(spacing: 28) {
                Stat(value: session.queue.done.count, label: "完成")
                Stat(value: s.correct, label: "答对")
                Stat(value: s.wrong, label: "答错")
                Stat(value: s.retired, label: "斩")
            }
            if s.answered > 0 {
                let mins = Int(Date().timeIntervalSince(s.started) / 60)
                Text("正确率 \(Int((Double(s.correct) / Double(s.answered) * 100).rounded()))% · 用时 \(max(1, mins)) 分钟")
                    .foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(QuestionType.allCases, id: \.self) { t in
                        if let v = s.byType[t] {
                            GridRow { Text(t.label); Text("\(v.right) / \(v.total)").monospacedDigit().foregroundStyle(.secondary) }
                        }
                    }
                }
                .font(.callout)
                Text(ReviewRating.allCases.map { "\($0.label) \(s.ratings[$0] ?? 0)" }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            HStack {
                Button("返回") { session.reset() }
                Button("再来一轮") { session.start() }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.large).padding(.top, 6)
            Spacer()
        }
    }
}

/// Start screen summary when a plan exists, Activity-summary style: big rings, stat column,
/// and a row with the target pace and the streak.
private struct PlanDashboard: View {
    @Environment(\.quizDensity) private var dens
    @ObservedObject var session: ReviewSession
    let plan: StudyPlan

    static let newColor = Color(red: 0.98, green: 0.07, blue: 0.31)      // Activity "move" pink-red
    static let reviewColor = Color(red: 0.25, green: 0.82, blue: 0.30)   // calmer system-like green
    static let totalColor = Color(red: 0.0, green: 0.74, blue: 0.90)     // slightly deeper cyan
    static let timeColor = Color(red: 0.0, green: 0.78, blue: 0.98)      // Activity "stand"-style blue

    private func frac(_ a: Int, _ b: Int) -> Double { b > 0 ? Double(a) / Double(b) : (a > 0 ? 1 : 0) }

    var body: some View {
        let o = session.overall, t = session.today
        let goal = ReviewSession.studyGoalMinutes
        let minutes = Int(t.studySeconds / 60)
        let rings = ActivityRings(values: [frac(t.newDone, t.newQuota), frac(t.reviewsDone, t.reviewTarget),
                                           t.studySeconds / Double(goal * 60)],
                                  colors: [Self.newColor, Self.reviewColor, Self.timeColor])
            .frame(width: dens == .normal ? 210 : 150, height: dens == .normal ? 210 : 150)
            .accessibilityHidden(true)
        let stats = VStack(alignment: .leading, spacing: dens == .normal ? 20 : 10) {
            StatRow(label: "今日新词", value: t.newDone, total: t.newQuota, color: Self.newColor)
            StatRow(label: "今日复习", value: t.reviewsDone, total: t.reviewTarget, color: Self.reviewColor)
            StatRow(label: "今日学习", value: minutes, total: goal, color: Self.timeColor, unit: "分钟")
        }
        .fixedSize()
        VStack(spacing: dens == .normal ? 32 : 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 44) { rings; stats }
                VStack(spacing: 24) { rings; stats }
            }
            .frame(maxWidth: .infinity)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { targetPill; streakPill }
                VStack(spacing: 8) { targetPill; streakPill }
            }
            Text("总进度 \(o.learned.formatted())/\(o.total.formatted()) · 已掌握 \(o.mastered.formatted())")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    @ViewBuilder private var targetPill: some View {
        if let t = targetLine {
            Pill { Label(t, systemImage: "flag.checkered").foregroundStyle(.secondary) }
        }
    }

    private var streakPill: some View {
        let on = session.streak > 0
        return Pill {
            HStack(spacing: 5) {
                Image(systemName: "flame.fill").foregroundStyle(on ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                if on {
                    Text("\(session.streak)").font(.system(.body, design: .rounded).weight(.bold)).monospacedDigit()
                    Text("天连续完成").foregroundStyle(.secondary)
                } else {
                    Text("今天完成就开始连续计数").foregroundStyle(.secondary)
                }
            }
        }
        .help("每天完成当天的新词和到期复习算一天；今天还没完成不会中断。")
    }

    private var targetLine: String? {
        guard let target = plan.targetDate else { return nil }
        let cal = Calendar.current
        let left = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: target).day ?? 0
        let remaining = max(0, session.overall.total - session.overall.learned)
        let due = WordbookModel.shared.dueItems.filter { !SessionPlanner.isNew($0) }.count
        var s = "目标 \(target.formatted(.dateTime.month().day())) · 还有 \(max(0, left)) 天"
        if let end = PlanMath.projectedDate(remaining: remaining, plan: plan, due: due, now: Date()) {
            let late = cal.dateComponents([.day], from: target, to: end).day ?? 0
            s += late > 0 ? " · 晚 \(late) 天" : " · 按计划"
        }
        return s
    }
}

private struct StatRow: View {
    let label: String, value: Int, total: Int, color: Color
    var detail: String? = nil
    var unit: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label).font(.subheadline).foregroundStyle(.secondary)
                if let detail { Text("· \(detail)").font(.subheadline).foregroundStyle(.tertiary) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value.formatted()).font(.system(size: 34, weight: .semibold, design: .rounded)).foregroundStyle(color)
                Text("/\(total.formatted())\(unit.map { " " + $0 } ?? "")").font(.system(size: 20, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            }
            .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct Pill<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.font(.callout).lineLimit(1).fixedSize()
            .frame(height: 20)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(.quaternary.opacity(0.5), in: Capsule())
    }
}

/// Concentric Activity-style rings, outermost first. Values above 1 wrap into a second lap.
struct ActivityRings: View {
    let values: [Double]
    let colors: [Color]
    var lineWidth: CGFloat = 20
    var gap: CGFloat = 3
    @State private var shown: [Double] = []

    var body: some View {
        ZStack {
            ForEach(values.indices, id: \.self) { i in
                Ring(value: i < shown.count ? shown[i] : 0, color: colors[i], lineWidth: lineWidth)
                    .padding(CGFloat(i) * (lineWidth + gap) + lineWidth / 2)
            }
        }
        .onAppear {
            shown = values.map { _ in 0 }
            withAnimation(.spring(response: 1.0, dampingFraction: 0.85).delay(0.1)) { shown = values }
        }
        .onChange(of: values) { _, v in withAnimation(.easeInOut(duration: 0.6)) { shown = v } }
    }
}

private struct Ring: View, Animatable {
    var value: Double
    let color: Color
    let lineWidth: CGFloat
    var animatableData: Double { get { value } set { value = newValue } }

    var body: some View {
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        let v = max(0, min(value, 2))
        // Exactly full (allow float noise): one seamless ring, no caps meeting at 12 o'clock.
        let full = abs(v - 1) < 0.0005
        let lap = v > 1 ? v - 1 : v
        let start = color.opacity(0.72)
        GeometryReader { g in
            let r = min(g.size.width, g.size.height) / 2
            ZStack {
                Circle().stroke(color.opacity(0.18), style: style)
                if full {
                    Circle().stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                } else if v > 1 {
                    // Past 100%: a solid full ring, then the extra lap in the same solid colour so its
                    // start blends in; only the leading cap gets a shadow, making the overlap read as intentional.
                    Circle().stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    Circle().trim(from: 0, to: max(lap, 0.0001)).stroke(color, style: style)
                    Circle().fill(color).frame(width: lineWidth, height: lineWidth)
                        .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 0)
                        .offset(x: r * cos(2 * .pi * lap), y: r * sin(2 * .pi * lap))
                } else if v > 0.002 {
                    Circle().trim(from: 0, to: max(lap, 0.0001))
                        .stroke(AngularGradient(colors: [start, color], center: .center,
                                                startAngle: .degrees(0), endAngle: .degrees(360 * max(lap, 0.01))), style: style)
                    // End cap with a soft shadow, as on Activity rings.
                    Circle().fill(color).frame(width: lineWidth, height: lineWidth)
                        .shadow(color: .black.opacity(v > 0.05 ? 0.35 : 0), radius: 3, x: 0, y: 0)
                        .offset(x: r * cos(2 * .pi * lap), y: r * sin(2 * .pi * lap))
                }
            }
            .rotationEffect(.degrees(-90))
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

/// Top-right corner: 测词汇量 / 测识字量 as small borderless icon buttons.
private struct TestLinks: View {
    @State private var vocab = false
    @State private var hanzi = false
    var body: some View {
        HStack(spacing: 4) {
            CornerButton(title: "测词汇量", symbol: LatinBookIcon.name, help: "测一下英语词汇量") { vocab = true }
            CornerButton(title: "测识字量", symbol: "character.book.closed.zh", help: "测一下认识多少个汉字") { hanzi = true }
        }
        .sheet(isPresented: $vocab) { VocabTestSheet() }
        .sheet(isPresented: $hanzi) { HanziTestSheet() }
    }
}

private struct CornerButton: View {
    let title: String
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Label { Text(title) } icon: {
                if symbol == LatinBookIcon.name { Image(nsImage: LatinBookIcon.image(pointSize: 13)) } else { Image(systemName: symbol) }
            }
                .font(.system(size: 13))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(hover ? Color.primary : Color.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hover ? 0.08 : 0)))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}


/// Closed book with a Latin "A": `a.book.closed` swaps in 字 under a Chinese UI, so draw our own
/// template from the non-localizing `book.closed` plus a Latin letter.
enum LatinBookIcon {
    static let name = "vocab.latin.book"
    static func image(pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSImage {
        let base = NSImage(systemSymbolName: "book.closed", accessibilityDescription: "测词汇量")!
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))!
        let size = base.size
        let img = NSImage(size: size, flipped: false) { r in
            base.draw(in: r)
            // Cover area: right of the spine, upper ~75% of the book.
            let cover = NSRect(x: r.minX + r.width * 0.30, y: r.minY + r.height * 0.22, width: r.width * 0.58, height: r.height * 0.66)
            let font = NSFont.systemFont(ofSize: pointSize * 0.62, weight: weight == .regular ? .semibold : weight)
            let a = NSAttributedString(string: "A", attributes: [.font: font, .foregroundColor: NSColor.black])
            let sz = a.size()
            a.draw(at: NSPoint(x: cover.midX - sz.width / 2, y: cover.midY - sz.height / 2 - font.descender * 0.5))
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "测词汇量"
        return img
    }
}


enum QuizDensity: Int { case normal, compact, grid
    var headword: CGFloat { self == .normal ? 40 : 30 }
}
private struct QuizDensityKey: EnvironmentKey { static let defaultValue = QuizDensity.normal }
extension EnvironmentValues {
    var quizDensity: QuizDensity { get { self[QuizDensityKey.self] } set { self[QuizDensityKey.self] = newValue } }
}

/// Shows the first density level whose layout fits the available height (spacers at their minimum),
/// filling the space; scrolls the densest level only if none fits.
struct FitHeight<Content: View>: View {
    let levels: [QuizDensity]
    @ViewBuilder var content: (QuizDensity) -> Content
    var body: some View {
        ViewThatFits(in: .vertical) {
            ForEach(levels, id: \.self) { d in content(d) }
            ScrollIfShort { content(levels.last ?? .normal) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Centres its content in the available height, and scrolls instead of overflowing (which would
/// push views up under the toolbar and clip the bottom) when the window is too short.
struct ScrollIfShort<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        GeometryReader { g in
            ScrollView(.vertical) {
                content().frame(maxWidth: .infinity, minHeight: g.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
