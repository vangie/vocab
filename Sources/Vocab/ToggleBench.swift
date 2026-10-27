import AppKit
import SwiftUI
import VocabCore

/// `Vocab --bench-toggle <word>`: times the 生词本 star toggle on a temp copy of the wordbook. Never touches the real DB.
enum ToggleBench {
    static func ms(_ t0: CFAbsoluteTime) -> String { String(format: "%.1fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000) }
    @MainActor static func run(_ a: [String]) {
        let word = a.first ?? "itinerary"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-bench-\(UUID().uuidString).sqlite")
        if let src = try? WordStore.defaultURL() { try? FileManager.default.copyItem(at: src, to: tmp) }
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let store = try? WordStore(url: tmp) else { print("no store"); exit(1) }
        let model = WordbookModel(store: store)
        let dicts = DictionarySelection.enabled()
        var t = CFAbsoluteTimeGetCurrent()
        guard let e = DictionaryService.shared.lookup(word, in: dicts, maxPerDictionary: 1).first else { print("no entry"); exit(1) }
        print("lookup", ms(t))
        for round in 1...3 {
            t = CFAbsoluteTimeGetCurrent(); _ = Lemmatizer.lemma(of: word, in: nil); print(round, "lemma", ms(t))
            t = CFAbsoluteTimeGetCurrent(); _ = WordCase.headwords(word, in: dicts); print(round, "headwords", ms(t))
            t = CFAbsoluteTimeGetCurrent(); model.add(entry: e, word: word, context: nil); print(round, "add(total)", ms(t))
            t = CFAbsoluteTimeGetCurrent(); model.reload(); print(round, "reload", ms(t))
            t = CFAbsoluteTimeGetCurrent(); _ = model.contains(word); print(round, "contains", ms(t))
            t = CFAbsoluteTimeGetCurrent(); model.remove(word: word); print(round, "remove(total)", ms(t))
        }
        // UI cost: an offscreen main window observing the temp model; each toggle publishes, then layout + draw.
        for mode in [Mode.lookup, Mode.words] {
            AppState.shared.mode = mode
            if mode == .words { AppState.shared.wordGroup = .all }
            let host = NSHostingView(rootView: MainView().environmentObject(LookupModel.shared).environmentObject(model)
                .environmentObject(SettingsModel.shared))
            let w = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            w.contentView = host
            host.layoutSubtreeIfNeeded(); host.display()
            for round in 1...6 {
                t = CFAbsoluteTimeGetCurrent()
                model.add(entry: e, word: word, context: nil)
                print(mode, round, "  model add", ms(t))
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001)); host.layoutSubtreeIfNeeded(); host.display()
                print(mode, round, "ui add", ms(t))
                t = CFAbsoluteTimeGetCurrent()
                model.remove(word: word)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001)); host.layoutSubtreeIfNeeded(); host.display()
                print(mode, round, "ui remove", ms(t))
            }
            // After: optimistic toggle; main thread only pays the enqueue, then one diffed publish when the write lands.
            for round in 1...6 {
                t = CFAbsoluteTimeGetCurrent()
                model.addInBackground(entry: e, word: word, context: nil)
                print(mode, round, "async add (main blocked)", ms(t))
                var landed = false
                model.addInBackground(entry: e, word: word, context: nil) { landed = true }
                while !landed { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001)) }
                t = CFAbsoluteTimeGetCurrent(); host.layoutSubtreeIfNeeded(); host.display(); print(mode, round, "async add ui", ms(t))
                landed = false
                t = CFAbsoluteTimeGetCurrent()
                model.removeInBackground(word: word) { landed = true }
                print(mode, round, "async remove (main blocked)", ms(t))
                while !landed { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001)) }
                t = CFAbsoluteTimeGetCurrent(); host.layoutSubtreeIfNeeded(); host.display(); print(mode, round, "async remove ui", ms(t))
            }
            w.contentView = nil
        }
        exit(0)
    }
}
