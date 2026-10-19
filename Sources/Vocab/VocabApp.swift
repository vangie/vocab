import SwiftUI
import VocabCore

@main
struct VocabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var lookup = LookupModel.shared
    @StateObject private var book = WordbookModel.shared
    @StateObject private var settings = SettingsModel.shared

    var body: some Scene {
        Window("生词", id: "main") {
            MainView()
                .environmentObject(lookup)
                .environmentObject(book)
                .environmentObject(settings)
                .frame(minWidth: 640, minHeight: 480)
        }
        .defaultSize(width: 860, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("单词") {
                Button("加入生词本") { lookup.addCurrentToWordbook() }
                    .keyboardShortcut("d", modifiers: [.command])
                Button("导出生词本为 CSV…") { book.exportCSV() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .frame(width: 760, height: 640)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsModel.shared.applyOnLaunch()
        // Re-render the current word when dictionary order/enabled/prefs change in Settings.
        NotificationCenter.default.addObserver(forName: .vocabDictionaryPrefsChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in
                let m = LookupModel.shared
                if !m.searchedTerm.isEmpty { m.show(m.searchedTerm, record: false) }
            }
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
