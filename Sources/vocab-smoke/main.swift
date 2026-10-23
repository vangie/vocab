import AppKit
import VocabCore
import WebKit

// Smoke-test harness for the parts that don't need a person at the trackpad.
//   vocab-smoke dicts
//   vocab-smoke lookup <word>
//   vocab-smoke play <word>
//   vocab-smoke render <word> <out.png> [dark] [dictID]
//   vocab-smoke click <word> [dictID]       simulate clicking the first speaker in the web view
//   vocab-smoke multitouch                  start device callbacks for 2 s

let args = CommandLine.arguments
let svc = DictionaryService.shared
func dicts(_ only: String? = nil) -> [DictionaryInfo] {
    var list = svc.activeDictionaries()
    if let only, let d = svc.availableDictionaries().first(where: { $0.id == only }) { return [d] }
    let avail = svc.availableDictionaries()
    for id in ["LDOCE5", "Macmillan2"] where !list.contains(where: { $0.id == id }) {
        if let d = avail.first(where: { $0.id == id }) { list.append(d) }
    }
    if let only { list = list.filter { $0.id == only } }
    return list
}

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }

guard args.count >= 2 else { fail("usage: vocab-smoke dicts|lookup|play|render|click|multitouch …") }

switch args[1] {
case "langs":   // language groups of every dictionary (Settings filter)
    for d in svc.availableDictionaries() {
        let l = DictionaryPrefs(bundleURL: d.bundleURL)?.languages ?? []
        print(d.name, l, DictionaryLanguageGroup.groups(languages: l, name: d.name, id: d.id).map(\.rawValue).sorted())
    }

case "ipa":
    // vocab-smoke ipa <word>…   IPA + audio file the quiz would use
    let ds = svc.activeDictionaries() + svc.availableDictionaries().filter { $0.id == "com.apple.dictionary.zh_CN-en.OCD" }
    for w in args.dropFirst(2) { let p = Phonetics.lookup(w, in: ds); print(w, p.ipa ?? "-", p.audio?.lastPathComponent ?? "-") }

case "plain":
    for e in svc.lookup(args[2], in: dicts(args.count > 3 ? args[3] : nil)) { print("=== [\(e.dictionary.id)] \(e.headword)\n\(e.plainText.prefix(600))") }

case "html":
    for e in svc.lookup(args[2], in: dicts(args.count > 3 ? args[3] : nil)) { print("=== [\(e.dictionary.id)]\n\(e.html)") }

case "review":
    // vocab-smoke review <word>…   materials for each question type (gloss, syllables, roots, distractors)
    var active = svc.activeDictionaries()
    // Same dictionaries as the app (Settings › 词典 selection) so slow ones show up here too.
    if let ids = UserDefaults(suiteName: "io.github.vangie.vocab")?.array(forKey: "enabledDictionaryIDs") as? [String] {
        let all = svc.availableDictionaries()
        let sel = ids.compactMap { id in all.first { $0.id == id } }
        if !sel.isEmpty { active = sel }
        print("dicts: \(active.map(\.id).joined(separator: ", "))")
    }
    let ote = svc.availableDictionaries().first { $0.id == "com.apple.dictionary.OTE" }
    let f = QuestionFactory(dicts: active, thesaurus: ote, book: [])
    for w in args.dropFirst(2) {
        let t0 = Date()
        let m = f.materials(for: w)
        print("== \(w)  [\(String(format: "%.2f", Date().timeIntervalSince(t0)))s]")
        print("   gloss: \(m.gloss.chinese ?? "-") | \(m.gloss.english ?? "-")")
        print("   syllables: \(m.syllables.joined(separator: "·")) (\(m.syllablesFromDictionary ? "dictionary" : "system"))")
        print("   roots: \(m.morphemes.prefix(3).map { "\($0.morpheme.display)=\($0.morpheme.meaning)" }.joined(separator: ", "))")
        print("   distractors: \(m.distractors.map { "\($0.word) (\($0.gloss.short))" }.joined(separator: "; "))")
        print("   audio: \(m.audio?.lastPathComponent ?? "-")  types: \(m.available.map(\.rawValue).sorted())")
    }

case "wordbook":
    // vocab-smoke wordbook <path>   open (and migrate, if old) a wordbook file and print its cards
    let st = try! WordStore(url: URL(fileURLWithPath: args[2]))
    if let m = st.migration { print("migrated \(m.cards) cards, backup: \(m.backup?.lastPathComponent ?? "-")") }
    for i in try! st.all() { let r = i.review; print("\(i.word)\tstate=\(r.state) S=\(r.stability.map { String($0) } ?? "nil") D=\(r.difficulty.map { String($0) } ?? "nil") reps=\(r.repetitions) lapses=\(r.lapses) due=\(r.due)") }

case "dicts":
    print("active:"); for d in svc.activeDictionaries() { print("  \(d.id)\t\(d.name)\t\(d.bundleURL?.path ?? "")") }
    print("available: \(svc.availableDictionaries().count)"); if args.count > 2 { for d in svc.availableDictionaries() { print("  \(d.id)\t\(d.name)") } }

case "lookup":
    let entries = svc.lookup(args[2], in: dicts())
    if entries.isEmpty { fail("no results") }
    for e in entries {
        let audio = EntryHTML.audioReferences(in: e.html)
        let resolved = audio.compactMap { a in e.resourceDirectory.map { $0.appendingPathComponent(a) } }
        let existing = resolved.filter { FileManager.default.fileExists(atPath: $0.path) }
        print("[\(e.dictionary.name)] \(e.headword)  html=\(e.html.count)B  audio=\(audio.count) (exist \(existing.count))")
        print("   res: \(e.resourceDirectory?.path ?? "-")")
        print("   \(e.snippet.prefix(110))")
    }

case "entries":   // entries <word> <dictID>: every entry with headword + audio refs
    guard let d = svc.availableDictionaries().first(where: { $0.id == args[3] }) else { fail("no dict") }
    for e in svc.lookup(args[2], in: [d], maxPerDictionary: 6) {
        let t = e.html.range(of: #"d:title="[^"]*""#, options: .regularExpression).map { String(e.html[$0]) } ?? "-"
        print("\(e.headword) \(t)  audio: \(EntryHTML.audioReferences(in: e.html).prefix(6).joined(separator: " "))")
    }

case "fixwords":   // fixwords [apply]: headword case + clean 释义 for the real wordbook (backs up first)
    let apply = args.contains("apply")
    let url = WordStore.defaultURL()
    if apply {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let bak = url.deletingLastPathComponent().appendingPathComponent("vocab-backup-pre-wordcase-\(f.string(from: Date())).sqlite")
        guard let src = try? WordStore(url: url) else { fail("open") }
        _ = src
        let sh = Process(); sh.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3"); sh.arguments = [url.path, ".backup '\(bak.path)'"]
        try? sh.run(); sh.waitUntilExit(); guard sh.terminationStatus == 0 else { fail("backup failed") }
        print("backup: \(bak.lastPathComponent)")
    }
    guard let store = try? WordStore(url: url), let items = try? store.all() else { fail("open") }
    let enabled = dicts(); let all = svc.availableDictionaries()
    var renamed = 0, reextracted = 0
    for it in items {
        if it.word.contains(where: \.isUppercase) {
            let c = WordCase.canonical(it.word, headwords: WordCase.headwords(it.word, in: enabled))
            if c != it.word { print("case: \(it.word) → \(c)"); renamed += 1; if apply { try? store.renameWord(id: it.id, to: c) } }
        }
        guard it.dictionary != "ECDICT", !it.dictionary.isEmpty, let d = all.first(where: { $0.name == it.dictionary }),
              let e = svc.lookup(it.word, in: [d], maxPerDictionary: 1).first else { continue }
        let sum = e.summary
        if sum != it.definition && !sum.isEmpty {
            print("def: \(it.word) [\(it.dictionary)]\n   old: \(it.definition.prefix(80))\n   new: \(sum.prefix(80))"); reextracted += 1
            if apply { try? store.setDefinition(id: it.id, sum) }
        }
    }
    print("\(apply ? "applied" : "dry run"): renamed \(renamed), re-extracted \(reextracted)")

case "snippet":   // snippet <word>: raw plain text start + snippet per enabled dictionary
    let only = args.count > 3 ? svc.availableDictionaries().filter { $0.name.contains(args[3]) } : dicts()
    for e in svc.lookup(args[2], in: only, maxPerDictionary: 1) {
        print("[\(e.dictionary.name)] RAW: \(e.plainText.prefix(200).replacingOccurrences(of: "\n", with: "⏎"))")
        if CommandLine.arguments.contains("html") { print(e.html.prefix(20000)) }; print("   SNIP: \(e.snippet)"); print("   SUM:  \(e.summary)")
    }

case "play":
    guard let e = svc.lookup(args[2], in: dicts()).first(where: { !EntryHTML.audioReferences(in: $0.html).isEmpty }),
          let dir = e.resourceDirectory, let a = EntryHTML.audioReferences(in: e.html).first else { fail("no audio") }
    let url = URL(string: EntryHTML.resourceBase(for: dir) + a)!
    print("playing \(url.absoluteString)")
    guard AudioPlayer.shared.play(urlString: url.absoluteString) else { fail("AVAudioPlayer failed") }
    print("ok, duration \(String(format: "%.2f", AudioPlayer.shared.currentDuration)) s")
    RunLoop.main.run(until: Date().addingTimeInterval(AudioPlayer.shared.currentDuration + 0.3))

case "render", "click":
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let word = args[2]
    let isRender = args[1] == "render"
    let out = isRender ? args[3] : ""
    let dark = args.contains("dark")
    let isPanel = args.contains("panel")
    let pageWidth: CGFloat = isPanel ? 460 : 760
    let only = args.dropFirst(isRender ? 4 : 3).first(where: { $0 != "dark" && $0 != "jsform" && $0 != "wiki" && $0 != "baike" && $0 != "panel" && !$0.hasPrefix("lang=") && $0 != "expand" })
    var entries = svc.lookup(word, in: dicts(only).filter { !$0.isNetwork })
    if args.contains("wiki"), let wd = svc.availableDictionaries().first(where: { $0.isWikipedia }) {
        // Same path as the app: our own fetch, then the entry (or the quiet failure note).
        // Optional "lang=xx" picks the switcher language.
        let lang = args.first { $0.hasPrefix("lang=") }.map { String($0.dropFirst(5)) }
        let sem = DispatchSemaphore(value: 0); var o = WikipediaClient.Outcome.failed
        Task.detached { o = await WikipediaClient.fetch(word, preferred: lang); sem.signal() }
        sem.wait()
        if let e = WikipediaClient.entry(o, dictionary: wd, term: word) { entries.append(e) }
        print("wikipedia:", { if case .found(let a) = o { return "found \(a.lang) \(a.title) avail \(a.available)" }; return "\(o)" }())
    }
    if args.contains("baike") {
        let sem = DispatchSemaphore(value: 0); var o = BaikeClient.Outcome.failed
        Task.detached { o = await BaikeClient.fetch(word); sem.signal() }
        sem.wait()
        if let e = BaikeClient.entry(o, term: word) { entries.append(e) }
        print("baike:", { if case .found(let l) = o { return "found \(l.title) others=\(l.hasOthers)" }; return "\(o)" }())
    }
    if entries.isEmpty { fail("no results") }
    if args.contains("jsform") {
        // Original (unmodified) LDOCE5 markup: javascript:new Audio("…").play() hrefs.
        let e = entries[0]
        let a = EntryHTML.audioReferences(in: e.html).first ?? "media/english/ameProns/appall.mp3"
        let html = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns:d=\"http://www.apple.com/DTDs/DictionaryService-1.0.rng\"><head><base href=\"file://\(e.resourceDirectory!.path)/KeyText.index\" /></head><body><a class=\"speaker\" href=\"javascript:new Audio(&quot;\(a)&quot;).play();\">x</a></body></html>"
        entries = [DictionaryEntry(id: "js", dictionary: e.dictionary, headword: e.headword, html: html, panelHTML: html, plainText: "", resourceDirectory: e.resourceDirectory)]
    }
    let factory = MainActor.assumeIsolated { EntryWebViewFactory() }
    let wv = MainActor.assumeIsolated { factory.makeWebView() }
    var heard: [(String, Bool)] = []
    MainActor.assumeIsolated { factory.onAudio = { heard.append(($0, $1)) } }
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: pageWidth, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    win.backgroundColor = dark ? NSColor(white: 0.12, alpha: 1) : .white
    win.contentView = wv
    win.orderFrontRegardless()
    let pageURL = MainActor.assumeIsolated {
        EntryWebViewFactory.pageURL(for: entries, showTitles: only == nil, panel: isPanel, emptyMessage: "")
    }
    wv.load(URLRequest(url: pageURL))
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    if isRender {
        let sem = DispatchSemaphore(value: 0); _ = sem
        var done = false
        if args.contains("expand") {
            wv.evaluateJavaScript("Array.from(document.querySelectorAll('iframe')).forEach(function(f){var d=f.contentDocument; if(d) d.querySelectorAll('.wordfams, .lm5ppBox').forEach(function(b){b.classList.remove('v-collapsed')})}); 0") { _, _ in }
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        }
        wv.evaluateJavaScript((dark ? "document.body.style.background='#1e1e1e';" : "document.body.style.background='#fff';") + "document.body.scrollHeight") { h, _ in
            let height = min(4000, max(400, (h as? Double) ?? 900))
            win.setContentSize(NSSize(width: pageWidth, height: height))
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            wv.takeSnapshot(with: nil) { img, err in
                guard let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { fail("snapshot failed: \(String(describing: err))") }
                try! png.write(to: URL(fileURLWithPath: out))
                print("wrote \(out) (\(Int(height)) px tall)")
                done = true
            }
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    } else {
        // Fire the speaker the same way a user would: mousedown then click on the first speaker.
        let js = """
        (function(){
          var fr = document.querySelectorAll('iframe'); var n = 0;
          for (var i = 0; i < fr.length; i++) {
            var d = fr[i].contentDocument; if (!d) continue;
            var a = d.querySelector('a.speaker, a.PronCodes, img[onmousedown]');
            if (a) {
              a.dispatchEvent(new MouseEvent('mousedown', {bubbles: true, cancelable: true}));
              a.click();
              n++; break;
            }
          }
          return n;
        })()
        """
        var done = false
        wv.evaluateJavaScript(js) { r, e in print("speakers clicked: \(r ?? "nil") \(e.map { "\($0)" } ?? "")"); done = true }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        for (u, ok) in heard { print("audio message: \(u) -> played=\(ok)") }
        if heard.isEmpty { fail("no audio message received") }
    }

case "profile":
    // vocab-smoke profile word…  — per-dictionary timings using the app's enabled set.
    _ = NSApplication.shared
    func ms(_ t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }
    var t = Date()
    _ = svc.activeDictionaries(); print("activeDictionaries: \(ms(t)) ms")
    t = Date(); let all = svc.availableDictionaries(); print("availableDictionaries: \(ms(t)) ms (\(all.count))")
    let ids = (UserDefaults(suiteName: "io.github.vangie.vocab")?.array(forKey: "enabledDictionaryIDs") as? [String]) ?? []
    let en = ids.compactMap { id in all.first { $0.id == id } }
    for q in args.dropFirst(2) {
        print("== \(q)")
        for d in en {
            t = Date(); let h0 = svc.headwords(q, method: 0, in: [d], maxPerDictionary: 5).count; let a = ms(t)
            t = Date(); let h1 = svc.headwords(q, method: 1, in: [d], maxPerDictionary: 40).count; let b = ms(t)
            t = Date(); let p = svc.headwords(String(q.prefix(1)), method: 1, in: [d], maxPerDictionary: 4000).count; let c = ms(t)
            t = Date(); let e = svc.lookup(q, in: [d]); let l = ms(t)
            let kb = e.reduce(0) { $0 + $1.html.utf8.count } / 1024
            print("\(d.shortName): exact \(a)ms(\(h0)) prefix \(b)ms(\(h1)) pool \(c)ms(\(p)) lookup \(l)ms(\(e.count) rec, \(kb) KB)")
            fflush(stdout)
        }
        t = Date(); let r = Suggester.suggest(q, in: en); print("suggest total: \(ms(t)) ms spelling=\(r.spelling.count)")
        t = Date(); let fb = Suggester.lookupWithFallback(q, in: en); print("lookupWithFallback total: \(ms(t)) ms"); fflush(stdout)
        t = Date(); MainActor.assumeIsolated { _ = EntryWebViewFactory.pageURL(for: fb.entries, showTitles: true, emptyMessage: "") }; print("page build (\(fb.entries.count) entries): \(ms(t)) ms")
        let sem = DispatchSemaphore(value: 0); t = Date()
        Task.detached { let o = await WikipediaClient.fetch(q); if case .found(let a) = o { print("wikipedia: found \(a.title)", terminator: "") } else { print("wikipedia: \(o)", terminator: "") }; sem.signal() }
        sem.wait(); print(" in \(ms(t)) ms"); fflush(stdout)
    }

case "hanzi":
    // vocab-smoke hanzi — sample spot-checks with Chinese glosses from the installed dictionaries.
    let avail = svc.availableDictionaries()
    let ds = ["com.apple.dictionary.zh_CN.SDCC", "com.vangie.cndict.xinhua"].compactMap { id in avail.first { $0.id == id } }
    for ch in args.dropFirst(2) {
        for d in ds { for e in svc.lookup(ch, in: [d], maxPerDictionary: 1) { print(ch, d.shortName, HanziGloss.firstSense(e.plainText, char: ch) ?? "nil") } }
    }
    if args.count > 2 { exit(0) }
    var rng = SystemRandomNumberGenerator()
    let t0 = Date()
    let run = HanziTestRun(list: HanziList.shared!, gloss: { c in
        for d in ds { for e in svc.lookup(c.char, in: [d], maxPerDictionary: 1) { if let g = HanziGloss.firstSense(e.plainText, char: c.char) { return g } } }
        return nil }, using: &rng)
    print("built in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
    for it in run.items where it.check { print(it.char, it.checkKind, it.choices, "✓", it.correct.sorted()) }

case "suggest":
    _ = NSApplication.shared
    for q in args.dropFirst(2) {
        let t0 = Date()
        let r = Suggester.suggest(q, in: dicts())
        let fb = Suggester.lookupWithFallback(q, in: dicts())
        print("\(q)  (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)")
        print("   matches:  \(r.matches.prefix(10).joined(separator: ", "))")
        print("   你是不是要找: \(r.spelling.joined(separator: ", "))")
        print("   lookup → \(fb.word): \(Set(fb.entries.map(\.dictionary.name)).sorted().joined(separator: ", "))")
    }

case "prefs":
    // vocab-smoke prefs <dictionary name part> <word> [key=value ...]
    //   Renders <word> with Vocab-local dictionary prefs (kept in a scratch defaults suite).
    let svc = DictionaryService.shared
    guard args.count > 3, let d = svc.availableDictionaries().first(where: { $0.name.contains(args[2]) || $0.shortName.contains(args[2]) }) else { fail("usage: prefs <dict> <word> [k=v ...]") }
    let suite = UserDefaults(suiteName: "io.github.vangie.vocab.smoke")!
    suite.removeObject(forKey: DictionaryPrefs.defaultsKey)
    svc.prefsStore = suite
    guard let p = DictionaryPrefs(bundleURL: d.bundleURL) else { fail("no Info.plist") }
    print("dictionary: \(d.name) id=\(p.bundleID) prefsHTML=\(p.prefsHTML?.lastPathComponent ?? "-") xsl=\(p.xsl?.lastPathComponent ?? "-")")
    print("defaults: \(p.defaults.sorted { $0.key < $1.key })")
    print("Dictionary.app: \(p.applePrefs.sorted { $0.key < $1.key })")
    var vals = p.systemEffective
    for kv in args.dropFirst(4) { let a = kv.split(separator: "=", maxSplits: 1).map(String.init); if a.count == 2 { vals[a[0]] = a[1] } }
    p.save(vals, suite)
    print("vocab overrides: \(p.vocabOverrides(suite).sorted { $0.key < $1.key })  ownTransform=\(p.needsOwnTransform(suite))")
    for e in svc.lookup(args[3], in: [d], maxPerDictionary: 1) {
        let han = e.html.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        print("html \(e.html.count) chars, CJK=\(han), audio refs=\(EntryHTML.audioReferences(in: e.html).count), css inlined=\(e.html.contains("@namespace d")), dark rules=\(e.html.contains("prefers-color-scheme: dark"))")
    }
    suite.removeObject(forKey: DictionaryPrefs.defaultsKey)

case "setquery":
    // vocab-smoke setquery <text>: set the running app's search query (test hook, no IME).
    DistributedNotificationCenter.default().postNotificationName(.init("io.github.vangie.vocab.setQuery"),
        object: args.count > 2 ? args[2] : "", userInfo: nil, deliverImmediately: true)
    print("posted")

case "axpoint":
    // vocab-smoke axpoint <x> <y> [--dc]   (AX coordinates, top-left origin)
    let pt = CGPoint(x: Double(args[2])!, y: Double(args[3])!)
    WordUnderCursor.debug = true
    WordUnderCursor.forceFallback = args.contains("--force-fallback")
    let res = WordUnderCursor.word(atAXPoint: pt, allowDoubleClick: args.contains("--dc"))
    print("\(pt) → \(res.map { "\($0.word) via \($0.method) bounds \($0.axBounds.map { "\($0)" } ?? "-")" } ?? "nil")")

case "axweb":
    // Find visible static text in a running browser and resolve the word at its centre via AX.
    //   vocab-smoke axweb com.google.Chrome
    let bid = args.count > 2 ? args[2] : "com.google.Chrome"
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first else { fail("\(bid) not running") }
    let appEl = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 0.5)
    func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
    var roots: [AXUIElement] = [appEl]
    if args.count > 3, let wins = attr(appEl, "AXWindows") as? [AXUIElement] {
        roots = wins.filter { ((attr($0, "AXTitle") as? String) ?? "").contains(args[3]) }
        print("windows matching: \(roots.count)")
    }
    var queue: [AXUIElement] = roots; var found: [(String, CGRect)] = []; var visited = 0
    while !queue.isEmpty, found.count < 3, visited < 4000 {
        let e = queue.removeFirst(); visited += 1
        if (attr(e, "AXRole") as? String) == "AXStaticText", let v = attr(e, "AXValue") as? String, v.count > 25,
           let pv = attr(e, "AXPosition"), let sv = attr(e, "AXSize") {
            var p = CGPoint.zero, z = CGSize.zero
            AXValueGetValue(pv as! AXValue, .cgPoint, &p); AXValueGetValue(sv as! AXValue, .cgSize, &z)
            if z.width > 40 && z.height > 8 && z.height < 40 { found.append((v, CGRect(origin: p, size: z))) }
        }
        if let kids = attr(e, "AXChildren") as? [AXUIElement] { queue.append(contentsOf: kids) }
    }
    print("visited \(visited) elements, text runs: \(found.count)")
    for (v, r) in found {
        let pt = CGPoint(x: r.minX + min(60, r.width / 3), y: r.midY)
        let res = WordUnderCursor.word(atAXPoint: pt, allowDoubleClick: false)
        print("rect \(r)"); print("text: \(v.prefix(50))…  at \(pt) → \(res.map { "\($0.word) via \($0.method), bounds \($0.axBounds.map { "\($0)" } ?? "-")" } ?? "nil")")
    }

case "multitouch":
    let n = ThreeFingerMonitor.shared.start()
    print("multitouch devices started: \(n)")
    RunLoop.main.run(until: Date().addingTimeInterval(2))
    ThreeFingerMonitor.shared.stop()

default:
    fail("unknown command")
}
