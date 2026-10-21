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
            case .check:
                // Same pinned top bar + progress as the quiz; 认识，斩 already retires, so no 斩 here.
                VStack(spacing: 0) {
                    SessionHeader(session: session, tag: "认识吗", showRetire: false)
                    FitHeight(levels: [.normal]) { _ in CheckScreen(session: session) }
                }
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
            if let l = session.tooEasyList { EaseBanner(session: session, list: l).padding([.horizontal, .top], 16) }
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
                    if let snap = session.resumable {
                        // A round interrupted by quitting/relaunching: pick it up where it was left.
                        Button { session.resume() } label: {
                            Text("继续上一轮（\(snap.queue.done.count)/\(snap.queue.total)）").font(.title3.weight(.semibold))
                                .frame(minWidth: 200, minHeight: 40)
                        }
                        .keyboardShortcut(.defaultAction).controlSize(.large)
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                        Button("放弃这一轮") { session.discardResumable() }.buttonStyle(.link).font(.callout)
                    } else if p.reviews + p.new == 0 {
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
                content(q, d).frame(maxWidth: 640).padding(.horizontal, d == .normal ? 32 : 20)
                    .id(q.id)
                    .contentShape(Rectangle())
                    .onHover { session.autoPaused = $0 }
            }
            Spacer(minLength: d == .normal ? 16 : 6)
        }
        .environment(\.quizDensity, d)
        .transaction { $0.animation = nil }   // reveal: no implicit layout animation
    }

    private var header: some View { SessionHeader(session: session) }

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
            if q.type != .recall {
                // Always laid out (hidden before the reveal) so nothing moves when the answer appears.
                let shown = session.phase == .answered
                AnswerBanner(session: session, q: q, active: shown)
                    .opacity(shown ? 1 : 0).allowsHitTesting(shown).accessibilityHidden(!shown)
            } else if session.phase == .answered {
                AnswerBanner(session: session, q: q, active: true)
            }
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

    @State private var width: CGFloat = 0

    var body: some View {
        // Two columns (1 2 / 3 4) unless an option needs more than 2 lines at half width. Decided from the
        // option texts and the width only, so it is the same before and after the reveal.
        let grid = useGrid
        Group {
            if grid {
                Grid(horizontalSpacing: 8, verticalSpacing: d == .normal ? 8 : 5) {
                    ForEach(Array(stride(from: 0, to: q.options.count, by: 2)), id: \.self) { r in
                        GridRow {
                            option(r, q.options[r], grid: true)
                            if r + 1 < q.options.count { option(r + 1, q.options[r + 1], grid: true) } else { Color.clear }
                        }
                    }
                }
            } else {
                VStack(spacing: d == .normal ? 8 : 5) {
                    ForEach(Array(q.options.enumerated()), id: \.offset) { i, opt in option(i, opt, grid: false) }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(GeometryReader { g in
            Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w }
        })
    }

    private var useGrid: Bool {
        guard q.options.count >= 2 else { return false }
        let w = width > 0 ? width : 600
        let text = (w - 8) / 2 - (d == .normal ? 90 : 80)
        guard text > 40 else { return false }
        let font = nsOptionFont
        let two = ceil(font.ascender - font.descender + font.leading) * 2 + 2
        return q.options.allSatisfy { o in
            let h = (o as NSString).boundingRect(with: NSSize(width: text, height: .greatestFiniteMagnitude),
                                                 options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                 attributes: [.font: font]).height
            return h <= two
        }
    }

    private var nsOptionFont: NSFont {
        if monospaced { return .monospacedSystemFont(ofSize: 15, weight: .regular) }
        let compact = d != .normal
        return q.type == .meaningToWord ? .systemFont(ofSize: compact ? 17 : 20, weight: .semibold)
                                        : .systemFont(ofSize: compact ? 15 : 17)
    }

    /// English word options 20 pt semibold, meanings 17 pt (smaller when the window is short).
    private var optionFont: Font {
        if monospaced { return .system(.title3, design: .monospaced) }
        let compact = d != .normal
        return q.type == .meaningToWord ? .system(size: compact ? 17 : 20, weight: .semibold)
                                        : .system(size: compact ? 15 : 17)
    }

    @ViewBuilder private func option(_ i: Int, _ opt: String, grid: Bool) -> some View {
        if session.phase == .asking {
            Button { session.choose(i) } label: { row(i, opt, grid: grid) }
                .buttonStyle(.plain)
                .modifier(NumberKey(n: i + 1, active: true))
        } else {
            // Answered: a plain row, so the speaker button inside it is clickable.
            row(i, opt, grid: grid)
        }
    }

    private func row(_ i: Int, _ opt: String, grid: Bool) -> some View {
        HStack(spacing: 12) {
            Text("\(i + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                // Never truncated: up to 2 lines in the grid (checked in useGrid), unlimited in one column.
                Text(opt).font(optionFont)
                    .multilineTextAlignment(.leading).lineLimit(grid ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                if q.type != .syllables {
                    // Fixed-height slot, reserved before the reveal too (hidden), so nothing moves; and whose width doesn't count toward the 2-column fit, so revealing
                    // the answer never flips the layout.
                    Color.clear.frame(height: 17).overlay(alignment: .leading) {
                        HStack(spacing: 6) {
                            if !q.optionNotes[i].isEmpty {
                                Text(q.optionNotes[i]).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if i < q.optionWords.count { PhoneticTag(session: session, word: q.optionWords[i], size: 13) }
                        }
                        .fixedSize()
                        .opacity(session.phase == .answered ? 1 : 0)
                        .allowsHitTesting(session.phase == .answered)
                    }
                    .clipped()
                }
            }
            Spacer(minLength: 0)
            if session.phase == .answered {
                if i == q.correctIndex { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                else if i == session.chosen { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
            }
        }
        .padding(.horizontal, d == .normal ? 14 : 10).padding(.vertical, d == .normal ? 10 : 5)
        .frame(maxWidth: .infinity, maxHeight: grid ? .infinity : nil, alignment: .leading)   // equal heights per row
        .background(background(i), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator.opacity(0.6)))
        .contentShape(Rectangle())
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
            // Front and back share one slot (the taller one sets the height), so flipping doesn't move the card.
            ZStack(alignment: .top) {
                VStack(spacing: 16) {
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
                            .modifier(RateKey(n: r.rawValue, active: session.revealed))
                        }
                    }
                    .padding(.top, 6)
                }
                .opacity(session.revealed ? 1 : 0).allowsHitTesting(session.revealed)
                if !session.revealed {
                    VStack(spacing: 16) {
                        Text("想一想它的意思").foregroundStyle(.secondary)
                        Button("显示释义") { session.flip() }
                            .keyboardShortcut(.space, modifiers: []).controlSize(.large)
                        Text("空格").font(.caption).foregroundStyle(.tertiary)
                    }
                }
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
            // Both states share one fixed slot so the card doesn't move on submit.
            let answered = session.phase == .answered
            ZStack(alignment: .top) {
                VStack(spacing: 6) {
                    // Top: what the user actually typed, aligned to the answer; bottom: the correct spelling.
                    Letters(marks: session.marks).frame(minHeight: 32)
                        .opacity(session.gaveUp ? 0 : 1)
                    Text(q.word).font(.system(size: 26, weight: .semibold, design: .serif))
                        .opacity(answered && !session.lastCorrect ? 1 : 0)
                }
                .padding(.top, 4)
                .opacity(answered ? 1 : 0)
                if !answered {
                    TextField("拼写这个单词，↩ 提交", text: $session.typed)
                        .textFieldStyle(.roundedBorder).font(.system(size: 22, design: .serif))
                        .multilineTextAlignment(.center).frame(maxWidth: 320)
                        .autocorrectionDisabled().focused($focused)
                        .onSubmit { session.submitSpelling() }
                        .onKeyPress(.tab) { session.hint(); return .handled }
                        .onAppear { DispatchQueue.main.async { focused = true } }
                        .padding(.top, 4)
                }
            }
            // Help row: always laid out (hidden after answering) so nothing moves.
            SpellingHelp(session: session, q: q, active: !answered)
                .opacity(answered ? 0 : 1).allowsHitTesting(!answered).accessibilityHidden(answered)
        }
    }
}

private struct SpellingHelp: View {
    @ObservedObject var session: ReviewSession
    let q: ReviewQuestion
    let active: Bool
    var body: some View {
        VStack(spacing: 4) {
            Text(session.hintsUsed > 0 ? SpellingHint.mask(q.word, shown: session.hintsUsed) : " ")
                .font(.system(size: 15, design: .monospaced)).foregroundStyle(.secondary).frame(height: 18)
            HStack(spacing: 16) {
                hintButton
                giveUpButton
            }
            .buttonStyle(.borderless).controlSize(.small).foregroundStyle(.secondary)
            Text("↩ 提交 · Tab 提示（提示后最高计 模糊） · ⌘↩ 看答案（计 忘了）")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
    @ViewBuilder private var hintButton: some View {
        Button { session.hint() } label: { Label("提示", systemImage: "lightbulb") }
            .help("显示下一个字母（Tab）；用了提示最高计 模糊")
            .disabled(session.hintsUsed >= SpellingHint.maxHints(q.word))
    }
    @ViewBuilder private var giveUpButton: some View {
        let b = Button { session.giveUpSpelling() } label: { Label("不会，看答案", systemImage: "eye") }
            .help("显示正确拼写，计为 忘了，稍后再考（⌘↩）")
        if active { b.keyboardShortcut(.return, modifiers: .command) } else { b }
    }
}

private struct Letters: View {
    let marks: [LetterMark]
    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(marks.enumerated()), id: \.offset) { _, m in
                // Missing letters are a blank slot with an orange underline (the user didn't type them).
                Text(String(m.char))
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .foregroundStyle(m.kind == .missing ? .clear : color(m.kind))
                    .strikethrough(m.kind == .extra, color: .red)
                    .overlay(alignment: .bottom) {
                        if m.kind == .missing { Rectangle().fill(.orange).frame(height: 2.5).padding(.horizontal, 2).offset(y: -3) }
                    }
                    .help(m.kind == .wrong ? "写成了 \(m.char)，应为 \(m.expected.map(String.init) ?? "")" : "")
            }
        }
        .help("你的输入：绿色 = 正确 · 红色 = 写错 · 橙色空位 = 漏写 · 删除线 = 多写")
    }
    private func color(_ k: LetterMark.Kind) -> Color {
        switch k { case .correct: .green; case .wrong: .red; case .missing: .orange; case .extra: .red }
    }
}

private struct AnswerBanner: View {
    @ObservedObject var session: ReviewSession
    let q: ReviewQuestion
    var active = true
    var body: some View {
        VStack(spacing: 6) {
            Label(session.lastCorrect ? "答对了" : "答错了，稍后再来一次",
                  systemImage: session.lastCorrect ? "checkmark.circle.fill" : "arrow.uturn.backward.circle.fill")
                .foregroundStyle(session.lastCorrect ? .green : .orange).font(.headline)
            HStack(spacing: 6) {
                LookupLink(session: session, word: q.word, active: active)
                // Syllables + IPA when they fit on the line, else just the IPA.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        if q.syllables.count > 1 { Text(q.syllables.joined(separator: "·")).foregroundStyle(.secondary).fixedSize() }
                        PhoneticTag(session: session, word: q.word, audio: q.audio).fixedSize()
                    }
                    PhoneticTag(session: session, word: q.word, audio: q.audio).fixedSize()
                }
                // A followed cross-reference is explained here only (options never show it).
                Text(q.gloss.short + (q.gloss.note.map { "（\($0)）" } ?? "")).foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.callout)
            if let m = q.morpheme, q.type == .roots {
                Text("\(m.morpheme.display)：\(m.morpheme.meaning)（\(m.morpheme.gloss)）").font(.callout).foregroundStyle(.secondary)
            }
            // Always takes its line, so the block has one height before and after.
            Text("评分：\(session.lastRating?.label ?? "—")").font(.caption).foregroundStyle(.tertiary)
                .opacity(session.lastRating == nil ? 0 : 1)
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
            if let l = session.easeHitThisRound, session.tooEasyList == l {
                EaseBanner(session: session, list: l).frame(maxWidth: 560).padding(.horizontal, 24)
            }
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


/// Top bar shared by every session screen: 结束 · type tag · done/total · 斩, then the progress bar.
private struct SessionHeader: View {
    @ObservedObject var session: ReviewSession
    var tag: String? = nil
    var showRetire = true
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                // Top-left, mirroring 斩 top-right; far from 继续 (bottom-right).
                Button { session.end() } label: { Label("结束", systemImage: "xmark") }
                    .help("结束本轮，查看小结（Esc）")
                    .keyboardShortcut(.cancelAction)
                if let t = tag ?? session.question?.type.label {
                    Text(t).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }
                Spacer()
                Text("\(session.queue.done.count) / \(session.queue.total)").monospacedDigit().foregroundStyle(.secondary)
                if showRetire {
                    Button { session.retire() } label: { Label { Text("斩") } icon: { CleaverIcon.swiftUI } }
                        .help("已掌握：不再复习这个词（⌘K）")
                        .keyboardShortcut("k", modifiers: .command)
                }
            }
            ProgressView(value: session.queue.progress).progressViewStyle(.linear)
        }
        .padding(.horizontal, 20).padding(.top, 14)
    }
}


/// 「这本词书太简单了」: most new words were 斩'd at first sight; suggest a harder list.
private struct EaseBanner: View {
    @ObservedObject var session: ReviewSession
    @ObservedObject private var plan = PlanModel.shared
    let list: ExamList
    @State private var test = false

    var body: some View {
        let estimate = plan.results.first?.estimate
        let active = Set(plan.plan.sources.filter(\.enabled).compactMap { s -> ExamList? in if case .list(let l) = s.id { return l }; return nil })
        let next = ListEase.recommend(after: list, estimate: estimate, exclude: active)
        let pct = Int((session.ease.share(list) * 100).rounded())
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.up.forward.circle.fill").foregroundStyle(Color.accentColor).font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("「\(list.title)」对你来说可能太简单了").font(.headline)
                Text(message(pct: pct, estimate: estimate, next: next))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let next {
                        Button("换到\(next.title)") { session.switchList(from: list, to: next) }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("继续当前词库") { session.dismissEase(list) }
                    if estimate == nil {
                        Button("先做词汇量测试") { test = true }.buttonStyle(.link)
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
            Button { session.dismissEase(list) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("不再提示这本词书")
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $test) { VocabTestSheet() }
    }

    private func message(pct: Int, estimate: Int?, next: ExamList?) -> String {
        var m = "最近 \(session.ease.samples(list)) 个新词里，\(pct)% 在第一次见到时就斩了。"
        if let e = estimate { m += "你的词汇量测试约 \(Adaptive.roundSize(e).formatted()) 词，" }
        if let next { m += "建议换成更难的「\(next.title)」；已斩和已掌握的词会自动跳过。" }
        else { m += "已经没有更难的词书了。" }
        return m
    }
}


/// A headword that opens 词典 (pointing hand, underline on hover), plus a small 「查词典」 button.
/// ⌘J does the same. Used in the answer feedback.
private struct LookupLink: View {
    @ObservedObject var session: ReviewSession
    let word: String
    var active = true
    @State private var hover = false
    var body: some View {
        HStack(spacing: 4) {
            Text(word).fontWeight(.semibold).underline(hover)
                .foregroundStyle(hover ? Color.accentColor : Color.primary)
                .onTapGesture { session.lookUp(word) }
                .onHover { h in
                    hover = h; session.overLookupLink = h
                    if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .help("在词典中查「\(word)」（⌘J）")
            Button { session.lookUp(word) } label: { Label("查词典", systemImage: "book").labelStyle(.titleAndIcon) }
                .buttonStyle(.borderless).controlSize(.small).font(.caption)
                .focusable(false)
                .onHover { session.overLookupLink = $0 }
                .help("在词典中查「\(word)」（⌘J）")
                .modifier(LookupKey(active: active))
        }
        .onDisappear { if hover { NSCursor.pop() }; session.overLookupLink = false }
    }
}


/// 「/əˈtjuːn/ 🔊」: IPA fetched in the background (cached), plus a speaker button that plays the
/// dictionary recording (American first) or the en-US voice. Clicks never advance or pick an option.
private struct PhoneticTag: View {
    @ObservedObject var session: ReviewSession
    let word: String
    var audio: URL? = nil
    var size: CGFloat? = nil
    @State private var p: Phonetic?

    var body: some View {
        HStack(spacing: 2) {
            if let ipa = p?.ipa { Text("/\(ipa)/").font(size.map { .system(size: $0) } ?? .caption).foregroundStyle(.secondary).lineLimit(1) }
            Button { session.pronounce(word, audio: audio ?? p?.audio) } label: {
                Image(systemName: "speaker.wave.2").font(size.map { .system(size: $0 - 1) } ?? .caption)
            }
            .buttonStyle(.borderless).focusable(false)
            .help("朗读 \(word)")
            .onHover { session.overLookupLink = $0 }
        }
        .task(id: word) {
            let w = word, dicts = ReviewSession.phoneticDicts
            p = await Task.detached(priority: .utility) { Phonetics.lookup(w, in: dicts) }.value
        }
    }
}


private struct LookupKey: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.keyboardShortcut("j", modifiers: .command) } else { content }
    }
}

private struct RateKey: ViewModifier {
    let n: Int; let active: Bool
    func body(content: Content) -> some View {
        if active { content.keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: []) } else { content }
    }
}
