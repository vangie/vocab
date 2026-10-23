import SwiftUI
import AppKit
import VocabCore

/// 每日词汇: the dictionary's empty state. 我的生词本 words first; 学习中/待复习 plan words only to top up.
enum DailyWords {
    static let maxCount = 10
    static let minFromBooks = 5

    static func pick(_ items: [WordItem], due: [WordItem], day: Date = Date()) -> [WordItem] {
        let seed = dayKey(day)
        func shuffled(_ a: [WordItem]) -> [WordItem] { a.sorted { hash("\(seed)|\($0.word)") < hash("\(seed)|\($1.word)") } }
        var out = Array(shuffled(items.filter { $0.bookID != nil && $0.familiarity != .retired }).prefix(maxCount))
        if out.count < minFromBooks {
            let have = Set(out.map(\.id))
            let dueIDs = Set(due.map(\.id))
            let extra = items.filter { $0.bookID == nil && !have.contains($0.id) && ($0.familiarity == .learning || dueIDs.contains($0.id)) }
            out += shuffled(extra).prefix(maxCount - out.count)
        }
        return out
    }

    static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d.addingTimeInterval(-2 * 3600))
        return "\(c.year!)-\(c.month!)-\(c.day!)"
    }

    /// FNV-1a: stable across launches (Swift's Hasher is seeded per process).
    static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }

    /// Short clean definition: drop a leading /ipa/, keep the first ~2 senses.
    static func shortDefinition(_ d: String) -> String {
        var s = d.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("/"), let end = s.dropFirst().firstIndex(of: "/") { s = String(s[s.index(after: end)...]).trimmingCharacters(in: .whitespaces) }
        if s.count > 90 { s = String(s.prefix(88)) + "…" }
        return s
    }
}

struct DailyWordsCard: View {
    let words: [WordItem]
    var onOpen: (String) -> Void
    var autoRotate = true
    @State private var index = 0
    @State private var hover = false
    @State private var phonetics: [String: Phonetic] = [:]
    @State private var cardHover = false
    private let timer = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 18) {
            if !words.isEmpty {
                Text("每日词汇").font(.system(size: 21, weight: .semibold)).foregroundStyle(.primary).padding(.bottom, 4)
                HStack(spacing: 10) {
                    arrow("chevron.left", -1)
                    card(words[index % words.count]).id(index).transition(.opacity)
                    arrow("chevron.right", 1)
                }
                if words.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(words.indices, id: \.self) { i in
                            Circle().fill(i == index ? Color.primary.opacity(0.55) : Color.secondary.opacity(0.25))
                                .frame(width: 6, height: 6)
                                .onTapGesture { withAnimation(.easeInOut(duration: 0.35)) { index = i } }
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { hover = $0 }
        .onReceive(timer) { _ in
            guard autoRotate, !hover, words.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.6)) { index = (index + 1) % words.count }
        }
        .task(id: words.map(\.word)) { await loadPhonetics() }
    }

    private func arrow(_ name: String, _ step: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.35)) { index = (index + step + words.count) % words.count }
        } label: {
            Image(systemName: name).font(.system(size: 13, weight: .semibold)).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.borderless).foregroundStyle(.secondary)
        .help(step < 0 ? "上一个" : "下一个")
        .opacity(words.count > 1 ? 1 : 0)
    }

    private func card(_ w: WordItem) -> some View {
        let p = phonetics[w.word]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(w.word).font(.system(size: 30, weight: .semibold, design: .serif)).lineLimit(1).minimumScaleFactor(0.6)
                if let ipa = p?.ipa { Text("/\(ipa.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/").font(.title3).foregroundStyle(.secondary) }
                Button { ReviewSession.shared.pronounce(w.word, audio: p?.audio) } label: {
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 14))
                }
                .buttonStyle(.borderless).speakerHover().help("朗读")
                Spacer(minLength: 0)
            }
            let d = DailyWords.shortDefinition(w.definition)
            if !d.isEmpty {
                Text(d).font(.body).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(w.bookID != nil ? "生词本" : "学习中").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Text("查看释义 →").font(.caption).foregroundStyle(cardHover ? Color.accentColor : Color.secondary.opacity(0.7))
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .frame(width: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(cardHover ? 0.35 : 0.18)))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { h in cardHover = h; if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        .onTapGesture { onOpen(w.word) }
        .help("在词典中查「\(w.word)」")
    }

    private func loadPhonetics() async {
        let ws = words.map(\.word)
        let dicts = DictionarySelection.enabled()
        for w in ws where phonetics[w] == nil {
            let p = await Task.detached { Phonetics.lookup(w, in: dicts) }.value
            phonetics[w] = p
        }
    }
}

/// `--render-dict-empty out.png [dark]`: the 每日词汇 empty state, offscreen, from a temp copy of the DB.
enum DictEmptyRender {
    @MainActor static func run(_ a: [String]) -> Never {
        guard let out = a.first else { print("usage: --render-dict-empty out.png [dark]"); exit(2) }
        UserDefaults.standard.addSuite(named: "io.github.vangie.vocab")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-render-\(UUID().uuidString).sqlite")
        try? FileManager.default.copyItem(at: WordStore.defaultURL(), to: tmp)
        let model = WordbookModel(store: try? WordStore(url: tmp))
        let words = DailyWords.pick(model.items, due: model.dueItems)
        let host = NSHostingView(rootView: DailyWordsCard(words: words, onOpen: { _ in }, autoRotate: false)
            .frame(width: 760, height: 520).background(Color(nsColor: .textBackgroundColor)))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: a.contains("dark") ? .darkAqua : .aqua)
        win.contentView = host
        win.orderFrontRegardless(); win.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        RunLoop.main.run(until: Date().addingTimeInterval(4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: (out as NSString).expandingTildeInPath))
        try? FileManager.default.removeItem(at: tmp)
        print("wrote \(out)"); exit(0)
    }
}

/// `--render-toolbar out.png [dark] [words]`: a titled window with the real main toolbar, offscreen.
enum ToolbarRender {
    @MainActor static func run(_ a: [String]) -> Never {
        guard let out = a.first else { print("usage: --render-toolbar out.png [dark] [words]"); exit(2) }
        if a.contains("words") { AppState.shared.mode = .words }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 120),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: a.contains("dark") ? .darkAqua : .aqua)
        win.contentView = NSHostingView(rootView: Color(nsColor: .windowBackgroundColor))
        MainToolbarController.launchFinished = true
        MainToolbarController.shared.attach(to: win)
        win.alphaValue = 1
        win.orderFrontRegardless(); win.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        print("items: \(win.toolbar?.items.map(\.itemIdentifier.rawValue) ?? [])")
        guard let v = win.contentView?.superview,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: (out as NSString).expandingTildeInPath))
        print("wrote \(out)"); exit(0)
    }
}
