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

    func lookUpUnderCursor() {
        let trusted = WordUnderCursor.isTrusted
        VocabLog.log("lookUpUnderCursor: AXIsProcessTrusted=\(trusted) mouse=\(NSEvent.mouseLocation)")
        SettingsModel.shared.refreshTrust()
        guard trusted else {
            WordUnderCursor.requestTrust()
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
        show(word: r.word, context: hit.context, entries: r.entries, at: NSEvent.mouseLocation, anchor: hit.screenBounds)
    }

    func show(word: String, context: String?, entries: [DictionaryEntry], at point: NSPoint, anchor: NSRect? = nil) {
        closePanelOnly()
        let size = NSSize(width: 480, height: 400)
        // Borderless like native Look Up: no titlebar or traffic lights, rounded corners.
        let p = LookupNSPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless, .nonactivatingPanel, .resizable],
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
        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .popover
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true
        let host = NSHostingView(rootView: PanelView(word: word, context: context, entries: entries, close: { [weak self] in self?.close() }))
        host.frame = bg.bounds
        host.autoresizingMask = [.width, .height]
        bg.addSubview(host)
        p.contentView = bg
        // Below and to the right of the pointer, kept on screen.
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        // Like Look Up: below the word (or the pointer), above it if there is no room.
        let a = anchor ?? NSRect(x: point.x, y: point.y - 9, width: 1, height: 18)
        var origin = NSPoint(x: a.minX - 24, y: a.minY - size.height - 6)
        if let vf = screen?.visibleFrame {
            if origin.y < vf.minY { origin.y = a.maxY + 6 }
            origin.x = min(max(vf.minX + 8, origin.x), vf.maxX - size.width - 8)
            origin.y = min(max(vf.minY + 8, origin.y), vf.maxY - size.height - 8)
        }
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
            if e.keyCode == 53 { self?.close(); return nil }
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

struct PanelView: View {
    let word: String
    let context: String?
    let entries: [DictionaryEntry]
    let close: () -> Void
    @State private var added = false
    @State private var selected: String? = nil

    private var dicts: [DictionaryInfo] {
        var seen = Set<String>(); return entries.compactMap { seen.insert($0.dictionary.id).inserted ? $0.dictionary : nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(word).font(.system(size: 17, weight: .semibold))
                Spacer()
                Button {
                    let pool = selected.map { s in entries.filter { $0.dictionary.id == s } } ?? entries
                    if let e = pool.first {
                        WordbookModel.shared.add(entry: e, word: word, context: context)
                        added = true
                    }
                } label: {
                    Label(added ? "已加入" : "加入生词本", systemImage: added ? "star.fill" : "star")
                }
                .disabled(entries.isEmpty || added)
                Button {
                    LookupModel.shared.search(word)
                    NSApp.activate(ignoringOtherApps: true)
                    close()
                } label: { Image(systemName: "arrow.up.forward.app") }
                .help("在「生词」中打开")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14).padding(.top, 26).padding(.bottom, 6)
            if dicts.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        chip("全部", selected == nil) { selected = nil }
                        ForEach(dicts) { d in chip(d.name, selected == d.id) { selected = d.id } }
                    }.padding(.horizontal, 10)
                }
                .padding(.bottom, 4)
            }
            Divider()
            EntryWebView(entries: selected.map { s in entries.filter { $0.dictionary.id == s } } ?? entries,
                         showTitles: selected == nil && dicts.count > 1, panel: true,
                         emptyMessage: "没有找到「\(word)」",
                         onLookup: { LookupModel.shared.search($0); NSApp.activate(ignoringOtherApps: true) })
        }
        .background(.regularMaterial)
        .onAppear { added = WordbookModel.shared.contains(word) }
    }

    private func chip(_ t: String, _ on: Bool, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(.system(size: 12)).padding(.horizontal, 7).padding(.vertical, 3)
                .background(on ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain)
    }
}


/// Look-Up-style word highlight: opaque yellow rounded box with the word redrawn crisply in
/// near-black on top (so the text never looks washed out), soft shadow and a short pop.
@MainActor
final class HighlightOverlay {
    static let shared = HighlightOverlay()
    private var window: NSWindow?

    func show(_ rect: NSRect, word: String, fontName: String? = nil, fontSize: CGFloat? = nil) {
        hide()
        let size = fontSize.flatMap { $0 > 4 ? $0 : nil } ?? max(9, rect.height * 0.8)
        let font = fontName.flatMap { NSFont(name: $0, size: size) } ?? NSFont.systemFont(ofSize: size, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0.08, alpha: 1)]
        let text = NSAttributedString(string: word, attributes: attrs)
        let ts = text.size()
        let padX: CGFloat = 4, padY: CGFloat = 2
        let boxW = max(rect.width, ts.width) + padX * 2
        let boxH = max(rect.height, ts.height) + padY * 2
        let margin: CGFloat = 12   // room for the pop scale and shadow
        let box = NSRect(x: rect.midX - boxW / 2, y: rect.midY - boxH / 2, width: boxW, height: boxH)
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
        container.shadowColor = NSColor.black.cgColor
        container.shadowOpacity = 0.35
        container.shadowRadius = 3
        container.shadowOffset = CGSize(width: 0, height: -1)

        let g = CAGradientLayer()
        g.frame = container.bounds
        g.colors = [NSColor(srgbRed: 1.0, green: 0.894, blue: 0.302, alpha: 1).cgColor,    // #FFE44D (top)
                    NSColor(srgbRed: 0.969, green: 0.827, blue: 0.235, alpha: 1).cgColor]  // #F7D33C (bottom)
        g.startPoint = CGPoint(x: 0.5, y: 1); g.endPoint = CGPoint(x: 0.5, y: 0)
        g.cornerRadius = min(5, boxH / 4)
        g.borderWidth = 0.5
        g.borderColor = NSColor(srgbRed: 0.80, green: 0.64, blue: 0.10, alpha: 0.9).cgColor
        g.masksToBounds = true
        container.addSublayer(g)

        let t = CATextLayer()
        t.string = text
        t.contentsScale = (NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main)?.backingScaleFactor ?? 2
        t.alignmentMode = .center
        t.frame = CGRect(x: 0, y: (boxH - ts.height) / 2, width: boxW, height: ts.height)
        container.addSublayer(t)

        root.layer?.addSublayer(container)
        w.contentView = root
        w.orderFrontRegardless()

        // Pop like native Look Up: 1.0 → 1.15 → 1.0 over ~0.2 s, around the centre.
        container.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        container.position = CGPoint(x: margin + boxW / 2, y: margin + boxH / 2)
        let a = CAKeyframeAnimation(keyPath: "transform.scale")
        a.values = [1.0, 1.15, 1.0]
        a.keyTimes = [0, 0.45, 1]
        a.duration = 0.2
        a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        container.add(a, forKey: "pop")
        window = w
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

