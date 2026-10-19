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
    let avail = svc.availableDictionaries()
    for id in ["LDOCE5", "Macmillan2", "Longman5"] where !list.contains(where: { $0.id == id }) {
        if let d = avail.first(where: { $0.id == id }) { list.append(d) }
    }
    if let only { list = list.filter { $0.id == only } }
    return list
}

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }

guard args.count >= 2 else { fail("usage: vocab-smoke dicts|lookup|play|render|click|multitouch …") }

switch args[1] {
case "dicts":
    print("active:"); for d in svc.activeDictionaries() { print("  \(d.id)\t\(d.name)\t\(d.bundleURL?.path ?? "")") }
    print("available: \(svc.availableDictionaries().count)")

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
    let only = args.dropFirst(isRender ? 4 : 3).first(where: { $0 != "dark" && $0 != "jsform" })
    var entries = svc.lookup(word, in: dicts(only))
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
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    win.backgroundColor = dark ? NSColor(white: 0.12, alpha: 1) : .white
    win.contentView = wv
    win.orderFrontRegardless()
    let pageURL = MainActor.assumeIsolated {
        EntryWebViewFactory.pageURL(for: entries, showTitles: only == nil, emptyMessage: "")
    }
    wv.load(URLRequest(url: pageURL))
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    if isRender {
        let sem = DispatchSemaphore(value: 0); _ = sem
        var done = false
        wv.evaluateJavaScript((dark ? "document.body.style.background='#1e1e1e';" : "document.body.style.background='#fff';") + "document.body.scrollHeight") { h, _ in
            let height = min(4000, max(400, (h as? Double) ?? 900))
            win.setContentSize(NSSize(width: 760, height: height))
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

case "axweb":
    // Find visible static text in a running browser and resolve the word at its centre via AX.
    //   vocab-smoke axweb com.google.Chrome
    let bid = args.count > 2 ? args[2] : "com.google.Chrome"
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first else { fail("\(bid) not running") }
    let appEl = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 0.5)
    func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
    var queue: [AXUIElement] = [appEl]; var found: [(String, CGRect)] = []; var visited = 0
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
        print("text: \(v.prefix(50))…  at \(pt) → \(res.map { "\($0.word) via \($0.method), bounds \($0.axBounds.map { "\($0)" } ?? "-")" } ?? "nil")")
    }

case "multitouch":
    let n = ThreeFingerMonitor.shared.start()
    print("multitouch devices started: \(n)")
    RunLoop.main.run(until: Date().addingTimeInterval(2))
    ThreeFingerMonitor.shared.stop()

default:
    fail("unknown command")
}
