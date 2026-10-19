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
        let body = NSSize(width: 440, height: 440)
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
        let host = NSHostingView(rootView: PanelView(word: word, context: context, entries: entries, close: { [weak self] in self?.close() }))
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

/// First sense or two of an entry, for the compact Look-Up-style list.
enum Excerpt {
    static func make(_ e: DictionaryEntry, limit: Int = 220) -> String {
        var t = e.plainText.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix(e.headword.lowercased()) { t = String(t.dropFirst(e.headword.count)).trimmingCharacters(in: .whitespaces) }
        guard t.count > limit else { return t }
        let cut = t.prefix(limit)
        if let i = cut.lastIndex(where: { "。；;.".contains($0) }), cut.distance(from: cut.startIndex, to: i) > limit / 2 {
            return String(cut[...i]) + " …"
        }
        return cut + "…"
    }
}

struct PanelView: View {
    let word: String
    let context: String?
    let entries: [DictionaryEntry]
    let close: () -> Void
    @State private var added = false
    /// nil = compact overview of every dictionary; otherwise the full entry of that dictionary.
    @State private var expanded: String? = nil

    private var dicts: [DictionaryInfo] {
        var seen = Set<String>(); return entries.compactMap { seen.insert($0.dictionary.id).inserted ? $0.dictionary : nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            if entries.isEmpty {
                Text("没有找到「\(word)」").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let id = expanded {
                HStack {
                    Button { expanded = nil } label: { Label("全部词典", systemImage: "chevron.left") }
                        .buttonStyle(.borderless)
                    Spacer()
                    Text(dicts.first { $0.id == id }?.name ?? "").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                EntryWebView(entries: entries.filter { $0.dictionary.id == id }, showTitles: false, panel: true,
                             emptyMessage: "没有找到「\(word)」",
                             onLookup: { LookupModel.shared.search($0); NSApp.activate(ignoringOtherApps: true) })
            } else {
                overview
            }
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
        .onAppear { added = WordbookModel.shared.contains(word) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(word).font(.system(size: 17, weight: .semibold))
            Spacer()
            Button {
                let pool = expanded.map { s in entries.filter { $0.dictionary.id == s } } ?? entries
                if let e = pool.first {
                    WordbookModel.shared.add(entry: e, word: word, context: context)
                    added = true
                }
            } label: {
                Label(added ? "已加入" : "加入生词本", systemImage: added ? "star.fill" : "star")
            }
            .disabled(entries.isEmpty || added)
            Button { openInMain() } label: { Image(systemName: "arrow.up.forward.app") }
                .help("在「生词」中打开")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(dicts) { d in
                    let es = entries.filter { $0.dictionary.id == d.id }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(d.name).font(.system(size: 20, weight: .bold))
                        Rectangle().fill(Color.primary.opacity(0.18)).frame(height: 0.5)
                        ForEach(es.prefix(2), id: \.id) { e in
                            Text(Excerpt.make(e)).font(.system(size: 13)).lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        Button("更多") { expanded = d.id }
                            .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                            .font(.system(size: 13))
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
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
        LookupModel.shared.search(word)
        NSApp.activate(ignoringOtherApps: true)
        close()
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

