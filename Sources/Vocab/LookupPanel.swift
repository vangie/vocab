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
        if let b = hit.screenBounds { HighlightOverlay.shared.show(b) }
        show(word: r.word, context: hit.context, entries: r.entries, at: NSEvent.mouseLocation, anchor: hit.screenBounds)
    }

    func show(word: String, context: String?, entries: [DictionaryEntry], at point: NSPoint, anchor: NSRect? = nil) {
        closePanelOnly()
        let size = NSSize(width: 480, height: 400)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: PanelView(word: word, context: context, entries: entries, close: { [weak self] in self?.close() }))
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


/// Yellow rounded highlight over the tapped word, like native Look Up. Click-through.
@MainActor
final class HighlightOverlay {
    static let shared = HighlightOverlay()
    private var window: NSWindow?

    func show(_ rect: NSRect) {
        hide()
        let r = rect.insetBy(dx: -3, dy: -2)
        let w = NSWindow(contentRect: r, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.ignoresMouseEvents = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let v = NSView(frame: NSRect(origin: .zero, size: r.size))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(calibratedRed: 1, green: 0.86, blue: 0.1, alpha: 0.5).cgColor
        v.layer?.cornerRadius = min(6, r.height / 3)
        w.contentView = v
        w.orderFrontRegardless()
        // Short "pop": grow from 85 % to 100 %.
        if let layer = v.layer {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: r.width / 2, y: r.height / 2)
            let a = CABasicAnimation(keyPath: "transform.scale")
            a.fromValue = 0.85; a.toValue = 1.0; a.duration = 0.12
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(a, forKey: "pop")
        }
        window = w
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}
