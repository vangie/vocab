import AppKit
import QuartzCore
import SwiftUI
import VocabCore

/// Look-Up-style floating panel shown on a three-finger tap.
@MainActor
final class LookupPanelController {
    static let shared = LookupPanelController()
    private var panel: NSPanel?
    private var monitors: [Any] = []

    private static var promptedForTrust = false

    func lookUpUnderCursor() {
        let trusted = WordUnderCursor.isTrusted
        VocabLog.log("lookUpUnderCursor: AXIsProcessTrusted=\(trusted) mouse=\(NSEvent.mouseLocation)")
        SettingsModel.shared.refreshTrust()
        guard trusted else {
            // The prompting API at most once per launch (each call can raise a system dialog).
            if !Self.promptedForTrust { Self.promptedForTrust = true; WordUnderCursor.requestTrust() }
            else { AccessibilityOnboarding.shared.show() }
            return
        }
        guard let hit = WordUnderCursor.current() else {
            VocabLog.log("AX: no word under cursor (and no selection)")
            NSSound.beep(); return
        }
        VocabLog.log("AX: word=\(hit.word) via \(hit.method) in \(hit.app) bounds=\(hit.axBounds.map { "\($0)" } ?? "-") context=\(hit.context ?? "-")")
        let dicts = DictionarySelection.enabled()
        // Fall back to the base form for inflected words ("appalled" → "appal").
        let r = Suggester.lookupWithFallback(hit.word, in: dicts)
        VocabLog.log("lookup \(hit.word) → \(r.word): \(r.entries.count) entries")
        if let b = hit.screenBounds { HighlightOverlay.shared.show(b, word: hit.word, fontName: hit.fontName, fontSize: hit.fontSize) }
        // Where the word was met (app, and page URL/title in browsers), probed before our panel covers it.
        let source = SourceProbe.source(atAXPoint: WordUnderCursor.axPoint(NSEvent.mouseLocation))
        VocabLog.log("source: app=\(source.app ?? "-") url=\(source.url == nil ? "-" : "yes")")
        WordbookModel.shared.recordLookup(word: r.word, context: hit.context, surface: hit.word, source: source)
        show(word: r.word, context: hit.context, surface: hit.word, source: source, entries: r.entries, at: NSEvent.mouseLocation, anchor: hit.screenBounds)
    }

    func show(word: String, context: String?, surface: String? = nil, source: WordSource? = nil, entries: [DictionaryEntry], at point: NSPoint, anchor: NSRect? = nil) {
        closePanelOnly()
        let body = NSSize(width: 460, height: 520)
        let arrowH: CGFloat = 10
        let size = NSSize(width: body.width, height: body.height + arrowH)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        // Like Look Up: directly below the word with an arrow pointing up at its centre;
        // flip above the word (arrow pointing down) when there is no room below.
        let a = anchor ?? NSRect(x: point.x, y: point.y - 9, width: 1, height: 18)
        var origin = NSPoint(x: a.midX - size.width / 2, y: a.minY - size.height - 2)
        var arrowUp = true
        if let vf = screen?.visibleFrame {
            if origin.y < vf.minY + 4 { origin.y = a.maxY + 2; arrowUp = false }
            origin.x = min(max(vf.minX + 6, origin.x), vf.maxX - size.width - 6)
            origin.y = min(max(vf.minY + 4, origin.y), vf.maxY - size.height - 4)
        }
        let arrowX = min(max(28, a.midX - origin.x), size.width - 28)

        // Borderless like native Look Up: no titlebar or traffic lights.
        let p = LookupNSPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let shape = PopoverShape.path(size: size, arrowX: arrowX, arrowH: arrowH, arrowUp: arrowUp, radius: 16)
        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .popover
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.maskImage = PopoverShape.mask(size: size, path: shape)
        // Thin light border following the rounded body and the arrow.
        bg.wantsLayer = true
        let border = CAShapeLayer()
        border.path = shape
        border.fillColor = nil
        border.strokeColor = NSColor.white.withAlphaComponent(0.22).cgColor
        border.lineWidth = 1
        let host = NSHostingView(rootView: PanelView(word: word, context: context, surface: surface, source: source, entries: entries, close: { [weak self] in self?.close() }))
        host.frame = NSRect(x: 0, y: arrowUp ? 0 : arrowH, width: body.width, height: body.height)
        bg.addSubview(host)
        bg.layer?.addSublayer(border)
        p.contentView = bg
        p.setFrameOrigin(origin)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { _ in
            Task { @MainActor in HighlightOverlay.shared.hide() }
        }
        p.orderFrontRegardless()
        VocabLog.log("panel shown at \(origin) visible=\(p.isVisible)")
        panel = p
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) { self.close() }
            }
        } as Any)
        // Esc while another app is frontmost (the panel doesn't activate us).
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { Task { @MainActor in self?.close() } }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 {
                // Editing the headword: Esc cancels the edit, not the panel.
                if self?.panel?.firstResponder is NSTextView { return e }
                self?.close(); return nil
            }
            return e
        } as Any)
    }

    func close() {
        closePanelOnly()
        HighlightOverlay.shared.hide()
    }

    private func closePanelOnly() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        panel?.close()
        panel = nil
    }
}

/// Borderless panels can't become key by default; allow it so Esc and the web view work.
final class LookupNSPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { LookupPanelController.shared.close() }
}

/// Popover outline with an arrow at the top (or bottom) pointing at the word.
enum PopoverShape {
    static func path(size: NSSize, arrowX: CGFloat, arrowH: CGFloat, arrowUp: Bool, radius r: CGFloat) -> CGPath {
        let body = CGRect(x: 0.5, y: arrowUp ? 0.5 : arrowH, width: size.width - 1, height: size.height - arrowH - 1)
        let p = CGMutablePath()
        let aw: CGFloat = 11
        // Start at the left end of the top edge, go clockwise (Cocoa: y up).
        p.move(to: CGPoint(x: body.minX + r, y: body.maxY))
        if arrowUp {
            p.addLine(to: CGPoint(x: arrowX - aw, y: body.maxY))
            p.addLine(to: CGPoint(x: arrowX, y: body.maxY + arrowH - 0.5))
            p.addLine(to: CGPoint(x: arrowX + aw, y: body.maxY))
        }
        p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.maxX, y: body.minY), radius: r)
        p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.minX, y: body.minY), radius: r)
        if !arrowUp {
            p.addLine(to: CGPoint(x: arrowX + aw, y: body.minY))
            p.addLine(to: CGPoint(x: arrowX, y: body.minY - arrowH + 0.5))
            p.addLine(to: CGPoint(x: arrowX - aw, y: body.minY))
        }
        p.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.minX, y: body.maxY), radius: r)
        p.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.maxX, y: body.maxY), radius: r)
        p.closeSubpath()
        return p
    }

    static func mask(size: NSSize, path: CGPath) -> NSImage {
        NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
            return true
        }
    }
}

struct PanelView: View {
    let initialWord: String
    let context: String?
    var surface: String? = nil
    var source: WordSource? = nil
    let initialEntries: [DictionaryEntry]
    let close: () -> Void
    @State private var word = ""
    @State private var entries: [DictionaryEntry] = []
    /// Local (instant) entries; network sources (Wikipedia, 百度百科) are appended as they arrive.
    @State private var localEntries: [DictionaryEntry] = []
    @State private var netEntries: [String: DictionaryEntry] = [:]
    @State private var netGeneration: [String: Int] = [:]
    @State private var added = false
    @State private var editing = false
    @State private var draft = ""
    @StateObject private var scroller = EntryScroller()
    @State private var currentSection = 0
    @State private var namesVersion = 0
    @FocusState private var fieldFocused: Bool

    init(word: String, context: String?, surface: String? = nil, source: WordSource? = nil,
         entries: [DictionaryEntry], close: @escaping () -> Void) {
        initialWord = word; self.context = context; self.surface = surface; self.source = source
        initialEntries = entries; self.close = close
        _word = State(initialValue: word); _entries = State(initialValue: entries)
        _localEntries = State(initialValue: entries)
    }

    private func rebuild() {
        let order = DictionarySelection.enabled().filter(\.isNetwork).map(\.id)
        entries = localEntries + order.compactMap { netEntries[$0] }
    }

    /// Fetch the enabled network sources for the word on screen; placeholders show until each arrives.
    private func loadNetwork(only: ((DictionaryInfo) -> Bool)? = nil) {
        let term = word
        let net = DictionarySelection.enabled().filter(\.isNetwork).filter { only?($0) ?? true }
        if only == nil { netEntries = [:] }
        for d in net {
            netEntries[d.id] = WikipediaClient.statusEntry(d.isWikipedia ? "正在查询维基百科…" : "正在查询百度百科…", dictionary: d, term: term)
        }
        rebuild()
        for d in net {
            let gen = (netGeneration[d.id] ?? 0) + 1
            netGeneration[d.id] = gen
            Task { @MainActor in
                let e = await LookupModel.shared.networkEntry(d, term)
                guard gen == netGeneration[d.id], term == word else { return }
                netEntries[d.id] = e
                rebuild()
            }
        }
    }

    var body: some View {
        let _ = namesVersion
        VStack(spacing: 0) {
            header
                .onReceive(NotificationCenter.default.publisher(for: .vocabDictionaryPrefsChanged)) { _ in namesVersion += 1 }
            Divider().opacity(0.6)
            if resultDicts.count > 1 { chips; Divider().opacity(0.4) }
            // Every dictionary's full entry at once, rendered like the main window (audio buttons play).
            EntryWebView(entries: entries, showTitles: true, panel: true,
                         emptyMessage: "没有找到「\(word)」",
                         onLookup: { relookup($0) },
                         scroller: scroller,
                         onSection: { currentSection = $0 })
            Divider().opacity(0.6)
            footerRow("在「生词」中打开", "book") { openInMain() }
            Divider().opacity(0.6).padding(.leading, 14)
            footerRow("配置词典", "gearshape") {
                close()
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .padding(.bottom, 4)
        }
        .onAppear { added = WordbookModel.shared.contains(word); loadNetwork() }
        .onReceive(NotificationCenter.default.publisher(for: .vocabWikiLanguageChanged)) { _ in loadNetwork(only: { $0.isWikipedia }) }
    }

    /// Dictionaries with results, in display order (one chip per entry section).
    private var resultDicts: [DictionaryInfo] {
        var seen = Set<String>(); var out: [DictionaryInfo] = []
        for e in entries where seen.insert(e.dictionary.id).inserted { out.append(e.dictionary) }
        return out
    }

    /// Compact chips (main-window tab style): click scrolls to the section; scroll-spy highlights.
    private var chips: some View {
        let _ = namesVersion
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(resultDicts.enumerated()), id: \.element.id) { i, d in
                        Button { currentSection = i; scroller.scroll(to: i) } label: {
                            Text(d.displayName)
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 2.5)
                                .background(currentSection == i ? Color.primary.opacity(0.14) : .clear, in: Capsule())
                                .foregroundStyle(currentSection == i ? Color.primary : Color.secondary)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(i)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
            }
            .onChange(of: currentSection) { _, i in withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(i, anchor: .center) } }
        }
        .onChange(of: entries.map(\.id)) { _, _ in currentSection = 0 }
    }

    private var header: some View {
        HStack(spacing: 8) {
            // Label and field share one fixed-height slot, same font/baseline: no jump when editing.
            ZStack(alignment: .leading) {
                if editing {
                    TextField("单词", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17, weight: .semibold))
                        .focusEffectDisabled()
                        .focused($fieldFocused)
                        .onSubmit { relookup(draft) }
                        .onExitCommand { editing = false }
                        .padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
                        .overlay(alignment: .bottom) { Rectangle().fill(Color.accentColor).frame(height: 1.5).padding(.horizontal, 4) }
                        .frame(maxWidth: 260, alignment: .leading)
                } else {
                    Button { draft = word; editing = true; DispatchQueue.main.async { fieldFocused = true } } label: {
                        Text(word).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 4)
                    .help("点按修改要查的词")
                    .onHover { $0 ? NSCursor.iBeam.push() : NSCursor.pop() }
                }
            }
            .frame(height: 24)
            Spacer()
            Button {
                if added {
                    WordbookModel.shared.remove(word: word); added = false
                } else if let e = entries.first {
                    WordbookModel.shared.add(entry: e, word: word, context: context, surface: surface, source: source)
                    added = true
                }
            } label: {
                Label {
                    Text(added ? "已在生词本" : "加入生词本")
                } icon: {
                    Image(systemName: added ? "star.fill" : "star").foregroundStyle(added ? Color.yellow : Color.accentColor)
                }
            }
            .disabled(entries.isEmpty)
            .help(added ? "点击移出生词本" : "加入生词本")
            Button { openInMain() } label: { Image(systemName: "arrow.up.forward.app") }
                .help("在「生词」中打开")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    }

    /// Look the (edited or linked) text up again inside the panel.
    private func relookup(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
        guard !t.isEmpty else { return }
        let r = Suggester.lookupWithFallback(t, in: DictionarySelection.enabled())
        word = r.word; localEntries = r.entries; entries = r.entries
        loadNetwork()
        added = WordbookModel.shared.contains(r.word)
    }

    private func footerRow(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18)
                Text(title)
                Spacer()
            }
            .font(.system(size: 13))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openInMain() {
        // Switch to 词典 (ReviewSession.shared keeps any 记词 session, so returning resumes it).
        AppState.shared.mode = .lookup
        LookupModel.shared.search(word)
        close()
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            // Main window was closed: a reopen event makes SwiftUI recreate it.
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: .init())
        }
    }
}

/// Look-Up-style word highlight: flat yellow box with the word redrawn crisply in black at
/// the original font and position, and a quick 1.2× jiggle.
@MainActor
final class HighlightOverlay {
    static let shared = HighlightOverlay()
    private var window: NSWindow?

    func show(_ rect: NSRect, word: String, fontName: String? = nil, fontSize: CGFloat? = nil) {
        hide()
        let size = fontSize.flatMap { $0 > 4 ? $0 : nil } ?? max(9, rect.height * 0.8)
        let font = fontName.flatMap { NSFont(name: $0, size: size) } ?? NSFont.systemFont(ofSize: size, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let text = NSAttributedString(string: word, attributes: attrs)
        let ts = text.size()
        let padX: CGFloat = 2.5, padY: CGFloat = 0
        let boxW = max(rect.width, ts.width) + padX * 2
        let boxH = max(rect.height, ts.height) + padY * 2
        let margin: CGFloat = 16   // room for the pop scale and shadow
        let box = NSRect(x: rect.minX - padX, y: rect.midY - boxH / 2, width: boxW, height: boxH)
        let frame = box.insetBy(dx: -margin, dy: -margin)

        let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        w.appearance = NSAppearance(named: .aqua)   // text on yellow stays dark in dark mode

        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        let container = CALayer()
        container.frame = NSRect(x: margin, y: margin, width: boxW, height: boxH)

        // Native Look Up: flat, saturated yellow, near-square corners, no border or gradient.
        let g = CALayer()
        g.frame = container.bounds
        g.backgroundColor = NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1).cgColor
        g.cornerRadius = 1.5
        container.addSublayer(g)

        let t = CATextLayer()
        t.string = text
        t.contentsScale = (NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main)?.backingScaleFactor ?? 2
        // Same position as the original text: left edge at the word's left edge.
        t.alignmentMode = .left
        t.frame = CGRect(x: padX, y: (boxH - ts.height) / 2, width: boxW, height: ts.height)
        container.addSublayer(t)

        root.layer?.addSublayer(container)
        w.contentView = root
        w.orderFrontRegardless()

        // Native jiggle: grow to ~1.2× fast, snap back with a tiny undershoot (box and text together).
        container.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        container.position = CGPoint(x: margin + boxW / 2, y: margin + boxH / 2)
        let a = CAKeyframeAnimation(keyPath: "transform.scale")
        a.values = [1.0, 1.2, 0.97, 1.0]
        a.keyTimes = [0, 0.4, 0.75, 1]
        a.duration = 0.2
        a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeOut)]
        container.add(a, forKey: "pop")
        window = w
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

