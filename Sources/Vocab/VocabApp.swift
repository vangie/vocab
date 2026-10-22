import SwiftUI
import VocabCore

@main
struct VocabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var lookup = LookupModel.shared
    @StateObject private var book = WordbookModel.shared
    @StateObject private var settings = SettingsModel.shared
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        Window("生词", id: "main") {
            MainView()
                .environmentObject(lookup)
                .environmentObject(book)
                .environmentObject(settings)
                .frame(minWidth: 680, minHeight: 520)
                .modifier(SettingsOpener())
        }
        .defaultSize(width: 860, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建生词本…") { book.promptNewBook() }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("单词") {
                Button("加入生词本") { lookup.addCurrentToWordbook() }
                    .keyboardShortcut("d", modifiers: [.command])
                Menu("导入到生词本") {
                    Button("CSV…") { book.importCSV() }
                    Button("Kindle 生词本（vocab.db）…") { book.importKindle() }
                }
                Menu("导出生词本") {
                    Button("CSV…") { book.exportCSV() }
                    Button("Anki 卡片包（.apkg）…") { book.exportAnki() }
                }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("学习") {
                Button("背诵计划…") { AppState.shared.openPlan() }.keyboardShortcut("p", modifiers: [.command, .option])
            }
            CommandGroup(after: .textEditing) {
                Button("查找") { NotificationCenter.default.post(name: .vocabFocusSearch, object: nil) }
                    .keyboardShortcut("f", modifiers: [.command])
                Button("搜索栏") { NotificationCenter.default.post(name: .vocabFocusSearch, object: nil) }
                    .keyboardShortcut("l", modifiers: [.command])
            }
            CommandGroup(after: .toolbar) {
                Button("放大文字") { lookup.zoomIn() }.keyboardShortcut("+", modifiers: [.command])
                Button("放大文字 ") { lookup.zoomIn() }.keyboardShortcut("=", modifiers: [.command])
                Button("缩小文字") { lookup.zoomOut() }.keyboardShortcut("-", modifiers: [.command])
                Button("实际大小") { lookup.zoom = 1.0 }.keyboardShortcut("0", modifiers: [.command])
            }
            CommandGroup(before: .sidebar) {
                Button("词典") { AppState.shared.mode = .lookup }.keyboardShortcut("1", modifiers: [.command])
                Button("记词") { AppState.shared.mode = .words }.keyboardShortcut("2", modifiers: [.command])
                Divider()
            }
            CommandMenu("前往") {
                Button("后退") { lookup.back() }.keyboardShortcut("[", modifiers: [.command]).disabled(!lookup.canGoBack || appState.mode != .lookup)
                Button("前进") { lookup.forward() }.keyboardShortcut("]", modifiers: [.command]).disabled(!lookup.canGoForward || appState.mode != .lookup)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
        .windowResizability(.contentSize)   // window height follows the tab / selected dictionary
    }
}

/// Opens the Settings window when AppState asks (toolbar 计划, ⌥⌘P, review prompt).
struct SettingsOpener: ViewModifier {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var state = AppState.shared
    func body(content: Content) -> some View {
        content.onChange(of: state.settingsRequest) { _, _ in
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--render-settings") {
            SettingsRender.run(Array(CommandLine.arguments[(i + 1)...]))
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-quiz") {
            QuizRender.run(Array(CommandLine.arguments[(i + 1)...]))
        }
        EntryWebViewFactory.onAction = { url in
            // vocab-action:wikilang/<code> from the Wikipedia language switcher.
            let s = url.absoluteString
            if let r = s.range(of: "wikilang/") { LookupModel.shared.setWikiLanguage(String(s[r.upperBound...])) }
        }
        DictionaryWatcher.shared.start()
        defer { MainToolbarController.launchFinished = true }
        SettingsModel.shared.applyOnLaunch()
        ReviewSession.applySchedulerSettings()
        if let m = WordbookModel.shared.store?.migrationV2 {
            VocabLog.log("wordbook upgraded to schema 2: \(m.words) words, backup \(m.backup?.lastPathComponent ?? "-")")
        }
        if let m = WordbookModel.shared.store?.migration {
            VocabLog.log("wordbook migrated to FSRS: \(m.cards) cards, backup \(m.backup?.lastPathComponent ?? "-")")
        }
        #if DEBUG || VOCAB_DEV_HOOKS
        // Dev-only test hook (debug builds, or `VOCAB_DEV_HOOKS=1 make app`): `vocab-smoke setquery <text>`
        // sets the search query without the keyboard/IME. Compiled out of release builds.
        DistributedNotificationCenter.default().addObserver(forName: .init("io.github.vangie.vocab.setQuery"), object: nil, queue: .main) { n in
            let q = n.object as? String ?? ""
            Task { @MainActor in AppState.shared.mode = .lookup; LookupModel.shared.query = q }
        }
        #endif
        // Re-render the current word when dictionary order/enabled/prefs change in Settings.
        NotificationCenter.default.addObserver(forName: .vocabDictionaryPrefsChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in LookupModel.shared.dictionariesChanged() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SettingsModel.shared.releaseOnQuit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running so three-finger lookup keeps working while the takeover is on.
        !SettingsModel.shared.takeoverEnabled
    }
}
