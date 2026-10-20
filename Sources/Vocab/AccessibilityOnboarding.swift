import AppKit
import SwiftUI
import VocabCore

/// Bob-style guide for the Accessibility grant: open System Settings, drag the app into the list.
/// Polls AXIsProcessTrusted (never the prompting API) and closes itself once granted.
@MainActor
final class AccessibilityOnboarding: ObservableObject {
    static let shared = AccessibilityOnboarding()
    @Published var granted = false
    @Published var showHelp = false
    private var window: NSWindow?
    private var timer: Timer?
    private var onGranted: (() -> Void)?

    func show(onGranted: (() -> Void)? = nil) {
        if let onGranted { self.onGranted = onGranted }
        granted = false; showHelp = false
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 470),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.title = "辅助功能权限"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: AccessibilityOnboardingView(model: self))
            w.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { AccessibilityOnboarding.shared.stopPolling() }
            }
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startPolling()
    }

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { AccessibilityOnboarding.shared.check() }
        }
    }
    func stopPolling() { timer?.invalidate(); timer = nil; onGranted = nil }

    private func check() {
        guard !granted, WordUnderCursor.isTrusted else { return }
        granted = true
        timer?.invalidate(); timer = nil
        SettingsModel.shared.refreshTrust()
        let f = onGranted; onGranted = nil
        f?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.window?.close() }
    }
}

struct AccessibilityOnboardingView: View {
    @ObservedObject var model: AccessibilityOnboarding

    var body: some View {
        VStack(spacing: 18) {
            if model.granted {
                Spacer()
                Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(.green)
                Text("已获得权限").font(.title2.weight(.semibold))
                Spacer()
            } else if model.showHelp {
                help
            } else {
                steps
            }
        }
        .padding(.horizontal, 32).padding(.top, 36).padding(.bottom, 18)
        .frame(width: 520, height: 470)
        .animation(.default, value: model.granted)
    }

    private var steps: some View {
        VStack(spacing: 18) {
            Text("生词三指查词需要辅助功能权限").font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            Text("需要读取光标下的文字，才能弹出释义。").foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("1. 打开「系统设置 › 隐私与安全性 › 辅助功能」")
                        Spacer()
                        Button("打开系统设置") { WordUnderCursor.openAccessibilitySettings() }
                    }
                    Divider()
                    Text("2. 把下面的图标拖到右侧的列表里，并打开开关")
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            AppIconDragSource().frame(width: 72, height: 72)
                                .help("拖到系统设置的辅助功能列表")
                            Text(Bundle.main.bundleURL.deletingPathExtension().lastPathComponent).font(.caption)
                        }
                        Spacer()
                    }
                }
                .padding(8)
            }
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("授权后会自动继续").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Button("反复提示需要权限？") { model.showHelp = true }.buttonStyle(.link).font(.caption)
                Spacer()
            }
        }
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("反复提示需要权限？").font(.title3.weight(.semibold))
            Text("每次重新构建或更新「生词」后，系统可能把它当成另一个应用，列表里的旧条目不再生效，就会一直提示没有权限。")
            Text("解决办法：").fontWeight(.medium)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. 打开「系统设置 › 隐私与安全性 › 辅助功能」。")
                Text("2. 在列表里选中「生词」（Vocab），点下方的「−」把它删掉。")
                Text("3. 把这里的图标重新拖进列表，并打开开关。")
                Text("4. 如果还不行，退出并重新打开「生词」。")
            }
            .fixedSize(horizontal: false, vertical: true)
            Text("当前应用位置：\(Bundle.main.bundlePath)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Spacer(minLength: 0)
            HStack {
                Button("打开系统设置") { WordUnderCursor.openAccessibilitySettings() }
                Spacer()
                Button("返回") { model.showHelp = false }.keyboardShortcut(.cancelAction)
            }
        }
    }
}

/// The app icon as a real drag source carrying the bundle's file URL.
struct AppIconDragSource: NSViewRepresentable {
    func makeNSView(context: Context) -> DragIconView { DragIconView() }
    func updateNSView(_ v: DragIconView, context: Context) {}

    final class DragIconView: NSView, NSDraggingSource {
        private var icon: NSImage { NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath) }
        override func draw(_ dirtyRect: NSRect) { icon.draw(in: bounds) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with e: NSEvent) {}
        override func mouseDragged(with e: NSEvent) {
            let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
            item.setDraggingFrame(bounds, contents: icon)
            beginDraggingSession(with: [item], event: e, source: self)
        }
        func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation {
            c == .outsideApplication ? [.copy, .link, .generic] : []
        }
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityLabel() -> String? { "生词应用图标，拖到辅助功能列表" }
    }
}
