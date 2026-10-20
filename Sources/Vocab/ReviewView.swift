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
            case .summary: SummaryScreen(session: session)
            case .loading: if session.question == nil { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) } else { QuestionScreen(session: session) }
            case .asking, .answered: QuestionScreen(session: session)
            case .check: CheckScreen(session: session)
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
            content
        }
    }

    private var content: some View {
        VStack(spacing: 14) {
            Spacer()
            let p = session.preview
            if plan.plan.configured {
                PlanDashboard(session: session, plan: plan.plan)
                if p.reviews + p.new == 0 {
                    Label("今天的任务完成了", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                } else {
                    Button { session.start() } label: { Text("开始").font(.title3.weight(.semibold)).frame(minWidth: 160, minHeight: 40) }
                    .keyboardShortcut(.defaultAction).controlSize(.extraLarge)
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).padding(.top, 4)
                    Text("1–4 选择 · 空格 翻面 · ↩ 提交 / 继续 · ⌘K 斩").font(.caption).foregroundStyle(.tertiary)
                }
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
            header
            Spacer(minLength: 16)
            if let q = session.question {
                content(q).frame(maxWidth: 560).padding(.horizontal, 32)
                    .id(q.id)
                    .contentShape(Rectangle())
                    .onHover { session.autoPaused = $0 }
            }
            Spacer(minLength: 16)
            footer
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                if let q = session.question {
                    Text(q.type.label).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }
                Spacer()
                Text("\(session.queue.done.count) / \(session.queue.total)").monospacedDigit().foregroundStyle(.secondary)
                Button { session.retire() } label: { Label("斩", systemImage: "scissors") }
                    .help("已掌握：不再复习这个词（⌘K）")
                    .keyboardShortcut("k", modifiers: .command)
            }
            ProgressView(value: session.queue.progress).progressViewStyle(.linear)
        }
        .padding(.horizontal, 20).padding(.top, 14)
    }

    @ViewBuilder private func content(_ q: ReviewQuestion) -> some View {
        VStack(spacing: 18) {
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
                Text(h).italic().foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3)
                    .font(.callout).padding(.top, 4)
            }
            if session.phase == .answered { AnswerBanner(session: session, q: q) }
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            // 结束 sits bottom-left, far from 斩 (top-right) and 继续 (bottom-right).
            Button("结束") { session.end() }.help("结束本轮，查看小结").buttonStyle(.borderless).foregroundStyle(.secondary)
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
    var body: some View {
        HStack(spacing: 10) {
            Text(q.word).font(.system(size: 40, weight: .semibold, design: .serif)).textSelection(.enabled)
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
    var body: some View {
        VStack(spacing: 8) {
            if let c = q.gloss.chinese { Text(c).font(.title2.weight(.semibold)).multilineTextAlignment(.center) }
            if let e = q.gloss.english {
                Text(ContextHint.blank(e, word: q.word)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }
}

private struct RootPrompt: View {
    let q: ReviewQuestion; let session: ReviewSession
    var body: some View {
        VStack(spacing: 8) {
            if let m = q.morpheme {
                HStack(spacing: 0) {
                    let w = Array(q.word)
                    Text(String(w[0..<m.range.lowerBound]))
                    Text(String(w[m.range])).foregroundStyle(Color.accentColor).underline()
                    Text(String(w[m.range.upperBound...]))
                }
                .font(.system(size: 40, weight: .semibold, design: .serif))
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

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(q.options.enumerated()), id: \.offset) { i, opt in
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
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(i), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator.opacity(0.6)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(session.phase != .asking)
                .modifier(NumberKey(n: i + 1, active: session.phase == .asking))
            }
        }
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

/// Start screen summary when a plan exists: Activity-style rings (今日新词 · 今日复习 · 总进度),
/// a legend, the target pace and the streak.
private struct PlanDashboard: View {
    @ObservedObject var session: ReviewSession
    let plan: StudyPlan

    static let newColor = Color(nsColor: .systemPink)
    static let reviewColor = Color(nsColor: .systemGreen)
    static let totalColor = Color(nsColor: .systemTeal)

    private func frac(_ a: Int, _ b: Int) -> Double { b > 0 ? Double(a) / Double(b) : (a > 0 ? 1 : 0) }

    var body: some View {
        let o = session.overall, t = session.today
        HStack(alignment: .center, spacing: 26) {
            ActivityRings(values: [frac(t.newDone, t.newQuota), frac(t.reviewsDone, t.reviewTarget), o.fraction],
                          colors: [Self.newColor, Self.reviewColor, Self.totalColor])
                .frame(width: 132, height: 132)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 9) {
                LegendRow(color: Self.newColor, label: "新词", value: "\(t.newDone)/\(t.newQuota)")
                LegendRow(color: Self.reviewColor, label: "复习", value: "\(t.reviewsDone)/\(t.reviewTarget)")
                LegendRow(color: Self.totalColor, label: "总进度",
                          value: "\(o.learned.formatted())/\(o.total.formatted())", detail: "已掌握 \(o.mastered.formatted())")
                if let target = targetLine {
                    Text(target).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "flame.fill").foregroundStyle(session.streak > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    if session.streak > 0 {
                        Text("\(session.streak)").font(.system(.title2, design: .rounded).weight(.bold)).monospacedDigit()
                        Text("天连续完成").foregroundStyle(.secondary)
                    } else {
                        Text("今天完成就开始连续计数").foregroundStyle(.secondary)
                    }
                }
                .help("每天完成当天的新词和到期复习算一天；今天还没完成不会中断。")
                .padding(.top, 2)
            }
            .font(.callout)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }

    private var targetLine: String? {
        guard let target = plan.targetDate else { return nil }
        let cal = Calendar.current
        let left = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: target).day ?? 0
        let remaining = max(0, session.overall.total - session.overall.learned)
        let due = WordbookModel.shared.dueItems.filter { !SessionPlanner.isNew($0) }.count
        var s = "目标 \(target.formatted(date: .abbreviated, time: .omitted))，还有 \(max(0, left)) 天"
        if let end = PlanMath.projectedDate(remaining: remaining, plan: plan, due: due, now: Date()) {
            let late = cal.dateComponents([.day], from: target, to: end).day ?? 0
            s += late > 0 ? " · 按现在的速度晚 \(late) 天" : " · 按计划进行"
        }
        return s
    }
}

private struct LegendRow: View {
    let color: Color, label: String, value: String
    var detail: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit().foregroundStyle(color)
            if let detail { Text("· \(detail)").foregroundStyle(.secondary).monospacedDigit() }
        }
    }
}

/// Concentric rings, outermost first. Values above 1 wrap into a second lap with an end shadow.
struct ActivityRings: View {
    let values: [Double]
    let colors: [Color]
    var lineWidth: CGFloat = 15
    var gap: CGFloat = 3
    @State private var shown: [Double] = []

    var body: some View {
        ZStack {
            ForEach(values.indices, id: \.self) { i in
                let inset = CGFloat(i) * (lineWidth + gap) + lineWidth / 2
                Ring(value: i < shown.count ? shown[i] : 0, color: colors[i], lineWidth: lineWidth)
                    .padding(inset)
            }
        }
        .onAppear {
            shown = values.map { _ in 0 }
            withAnimation(.spring(response: 0.9, dampingFraction: 0.85)) { shown = values }
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
        ZStack {
            Circle().stroke(color.opacity(0.18), style: style)
            Circle().trim(from: 0, to: min(v, 1)).stroke(color, style: style).rotationEffect(.degrees(-90))
            if v > 1 {
                // Second lap: a cap with a soft shadow shows where it overlaps.
                Circle().trim(from: 0, to: v - 1).stroke(color, style: style).rotationEffect(.degrees(-90))
                    .shadow(color: .black.opacity(0.35), radius: 2)
            } else if v > 0.001 {
                // Keep a visible dot for tiny non-zero values.
                Circle().trim(from: 0, to: 0.0001).stroke(color, style: style).rotationEffect(.degrees(-90))
            }
        }
    }
}
