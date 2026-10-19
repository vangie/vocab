import AppKit
import SwiftUI
import VocabCore

/// Look-Up-style floating panel shown on a three-finger tap.
@MainActor
final class LookupPanelController {
    static let shared = LookupPanelController()
    private var panel: NSPanel?
    private var monitors: [Any] = []

    func lookUpUnderCursor() {
        guard WordUnderCursor.isTrusted else {
            WordUnderCursor.requestTrust()
            return
        }
        guard let hit = WordUnderCursor.current() else { NSSound.beep(); return }
        let dicts = DictionarySelection.enabled()
        let entries = DictionaryService.shared.lookup(hit.word, in: dicts)
        show(word: hit.word, context: hit.context, entries: entries, at: NSEvent.mouseLocation)
    }

    func show(word: String, context: String?, entries: [DictionaryEntry], at point: NSPoint) {
        close()
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
        var origin = NSPoint(x: point.x - 40, y: point.y - size.height - 18)
        if let vf = screen?.visibleFrame {
            if origin.y < vf.minY { origin.y = point.y + 18 }
            origin.x = min(max(vf.minX + 8, origin.x), vf.maxX - size.width - 8)
            origin.y = min(max(vf.minY + 8, origin.y), vf.maxY - size.height - 8)
        }
        p.setFrameOrigin(origin)
        p.orderFrontRegardless()
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
