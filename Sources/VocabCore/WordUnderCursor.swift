import AppKit
import ApplicationServices

/// Finds the word under the mouse pointer through the Accessibility API.
///
/// Strategy, in order:
/// 1. Chromium/Electron apps get `AXManualAccessibility = true` (once per pid) so they expose web content.
/// 2. Text markers (`AXTextMarkerForPosition` …) — what WebKit and Chromium implement for web content.
/// 3. Plain text ranges (`AXRangeForPosition` / `AXStringForRange`) — native text views.
/// 4. Last resort: double-click to select the word and read the selection (skipped over links).
public enum WordUnderCursor {
    public struct Result: Sendable {
        public let word: String
        public let context: String?
        /// Word bounds in AX (top-left origin) screen coordinates, if known.
        public let axBounds: CGRect?
        public let method: String
        public let app: String

        /// Bounds converted to Cocoa (bottom-left origin) screen coordinates.
        public var screenBounds: NSRect? {
            guard let b = axBounds, b.width > 0, b.height > 0 else { return nil }
            return WordUnderCursor.cocoaRect(fromAX: b)
        }
    }

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    public static func requestTrust() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    public static func openAccessibilitySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }

    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    static func axPoint(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }

    public static func cocoaRect(fromAX r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    // MARK: - Chromium / Electron

    private static var enabledPIDs = Set<pid_t>()
    static let chromiumBundlePrefixes = ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "org.chromium",
                                         "com.vivaldi", "company.thebrowser", "com.operasoftware", "com.tinyspeck.slackmacgap",
                                         "com.microsoft.VSCode", "com.todesktop", "com.electron"]

    static func isChromiumLike(_ app: NSRunningApplication) -> Bool {
        let id = app.bundleIdentifier ?? ""
        if chromiumBundlePrefixes.contains(where: { id.hasPrefix($0) }) { return true }
        // Electron apps ship this framework.
        if let url = app.bundleURL?.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"),
           FileManager.default.fileExists(atPath: url.path) { return true }
        return false
    }

    /// Ask Chromium/Electron to build its accessibility tree. Returns true if it was just enabled.
    @discardableResult
    static func enableAccessibility(pid: pid_t) -> Bool {
        guard !enabledPIDs.contains(pid), let app = NSRunningApplication(processIdentifier: pid), isChromiumLike(app) else { return false }
        enabledPIDs.insert(pid)
        let el = AXUIElementCreateApplication(pid)
        let r = AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if r != .success { AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
        VocabLog.log("AX: enabled accessibility for \(app.bundleIdentifier ?? "\(pid)") (AXManualAccessibility=\(r.rawValue))")
        return true
    }

    // MARK: - Entry point

    nonisolated(unsafe) public static var debug = false
    static func dbg(_ s: @autoclosure () -> String) { if debug { print("  [ax] " + s()) } }

    public static func current() -> Result? {
        word(atAXPoint: axPoint(NSEvent.mouseLocation))
    }

    /// Word at a point in AX (top-left origin) coordinates.
    public static func word(atAXPoint pt: CGPoint, allowDoubleClick: Bool = true) -> Result? {
        guard isTrusted else { return nil }
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.5)

        var elRef: AXUIElement?
        var err = AXUIElementCopyElementAtPosition(sys, Float(pt.x), Float(pt.y), &elRef)
        var pid: pid_t = 0
        if let el = elRef { AXUIElementGetPid(el, &pid) }
        if pid == 0, let front = NSWorkspace.shared.frontmostApplication { pid = front.processIdentifier }
        let appName = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)"

        if enableAccessibility(pid: pid) {
            // Chromium builds the tree asynchronously; give it a moment and look again.
            for _ in 0..<6 {
                Thread.sleep(forTimeInterval: 0.08)
                elRef = nil
                err = AXUIElementCopyElementAtPosition(sys, Float(pt.x), Float(pt.y), &elRef)
                if let el = elRef, role(el) != "AXWindow", role(el) != "AXGroup" || textMarker(el, at: pt) != nil { break }
            }
        }
        guard err == .success, let el = elRef else {
            VocabLog.log("AX: no element at point (err \(err.rawValue)) in \(appName)")
            return allowDoubleClick ? selectionFallback(app: appName, point: pt, element: nil) : nil
        }
        let r0 = role(el) ?? "?"
        if let r = wordViaTextMarkers(el, point: pt, app: appName) { return r }
        if let r = wordViaRanges(el, point: pt, app: appName) { return r }
        VocabLog.log("AX: element role=\(r0) in \(appName) gave no text (markers and ranges failed)")
        return allowDoubleClick ? selectionFallback(app: appName, point: pt, element: el) : nil
    }

    // MARK: - Text markers (WebKit / Chromium)

    static func param(_ el: AXUIElement, _ attr: String, _ value: CFTypeRef) -> CFTypeRef? {
        var out: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(el, attr as CFString, value, &out) == .success ? out : nil
    }

    static func textMarker(_ el: AXUIElement, at pt: CGPoint) -> CFTypeRef? {
        var p = pt
        guard let v = AXValueCreate(.cgPoint, &p) else { return nil }
        return param(el, "AXTextMarkerForPosition", v)
    }

    static func rect(_ v: CFTypeRef?) -> CGRect? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        return AXValueGetValue(v as! AXValue, .cgRect, &r) ? r : nil
    }

    static func wordViaTextMarkers(_ start: AXUIElement, point pt: CGPoint, app: String) -> Result? {
        // The marker API may live on the element or an ancestor (web area).
        var el: AXUIElement? = start
        var marker: CFTypeRef?
        var host: AXUIElement?
        for _ in 0..<8 {
            guard let e = el else { break }
            if let m = textMarker(e, at: pt) { marker = m; host = e; break }
            el = parent(e)
        }
        guard let m = marker, let h = host else { return nil }
        var best: (String, CGRect?)?
        for attr in ["AXLeftWordTextMarkerRangeForTextMarker", "AXRightWordTextMarkerRangeForTextMarker"] {
            guard let range = param(h, attr, m),
                  let s = param(h, "AXStringForTextMarkerRange", range) as? String else { continue }
            let w = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !w.isEmpty, w.count < 60 else { continue }
            let b = rect(param(h, "AXBoundsForTextMarkerRange", range))
            if let b, b.insetBy(dx: -2, dy: -2).contains(pt) { best = (w, b); break }
            if best == nil { best = (w, b) }
        }
        guard let (word, bounds) = best else { return nil }
        var context: String?
        if let sr = param(h, "AXSentenceTextMarkerRangeForTextMarker", m) {
            context = (param(h, "AXStringForTextMarkerRange", sr) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Result(word: word, context: context, axBounds: bounds, method: "textMarker", app: app)
    }

    // MARK: - Ranges (native text)

    static func wordViaRanges(_ el: AXUIElement, point: CGPoint, app: String) -> Result? {
        var p = point
        guard let axPoint = AXValueCreate(.cgPoint, &p),
              let rv = param(el, kAXRangeForPositionParameterizedAttribute, axPoint),
              CFGetTypeID(rv) == AXValueGetTypeID() else { return nil }
        var hit = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &hit), hit.location >= 0 else { return nil }
        // Chromium/Electron answer AXRangeForPosition with location 0 regardless of the point,
        // which made every tap pick the first word of the line. Verify the index against
        // AXBoundsForRange and, if it doesn't contain the point, locate the character by bounds.
        let charBounds: (Int) -> CGRect? = { i in
            var r = CFRange(location: i, length: 1)
            guard let v = AXValueCreate(.cfRange, &r), let b = rect(param(el, kAXBoundsForRangeParameterizedAttribute, v)),
                  b.width > 0, b.height > 0 else { return nil }
            return b
        }
        dbg("range hit=\(hit.location) len=\(hit.length) count=\(characterCount(el)) b(hit)=\(String(describing: charBounds(hit.location))) b(1)=\(String(describing: charBounds(1))) b(5)=\(String(describing: charBounds(5))) el=\(String(describing: rect(frameOf(el))))")
        if !(charBounds(hit.location)?.insetBy(dx: -1, dy: -1).contains(point) ?? false) {
            let n = characterCount(el)
            dbg("range: index not under point, searching \(n) chars by bounds")
            guard n > 0, let i = indexForPoint(point, count: n, bounds: charBounds) else {
                return nil   // never fall back to index 0: let the next strategy (double-click) try
            }
            hit.location = i
            dbg("range: bounds search → index \(i) \(String(describing: charBounds(i)))")
        }
        let total = characterCount(el)
        let start = max(0, hit.location - 200)
        // Chromium errors on ranges past the end, so clamp to the real length.
        var window = CFRange(location: start, length: total > 0 ? min(400, total - start) : 400)
        var text = string(el, range: &window)
        if text == nil {
            window = CFRange(location: start, length: hit.location - start + 40)
            text = string(el, range: &window)
        }
        dbg("range: text window \(window.location)+\(window.length) got \(text.map { ($0 as NSString).length } ?? -1) chars")
        guard let t = text, !t.isEmpty, let w = wordRange(in: t, at: hit.location - start) else { return nil }
        var wr = CFRange(location: start + w.range.location, length: w.range.length)
        var bounds: CGRect?
        if let rangeVal = AXValueCreate(.cfRange, &wr) {
            bounds = rect(param(el, kAXBoundsForRangeParameterizedAttribute, rangeVal))
        }
        // Validate: the word box must contain the point and be smaller than the element.
        if let b = bounds {
            let elFrame = rect(frameOf(el))
            let tooBig = elFrame.map { b.width >= $0.width * 0.95 && $0.width > 60 } ?? false
            if !b.insetBy(dx: -2, dy: -2).contains(point) || tooBig || b.width <= 0 {
                dbg("range: rejected \(w.word) bounds \(b)")
                return nil
            }
        } else { return nil }
        return Result(word: w.word, context: w.context, axBounds: bounds, method: "range", app: app)
    }

    static func frameOf(_ el: AXUIElement) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, "AXFrame" as CFString, &v) == .success ? v : nil
    }

    static func characterCount(_ el: AXUIElement) -> Int {
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXNumberOfCharactersAttribute as CFString, &v) == .success, let n = v as? Int, n > 0 { return n }
        if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success, let t = v as? String, !t.isEmpty { return (t as NSString).length }
        // Chromium/Electron static text: no character count and empty AXValue, but
        // AXStringForRange works (it clamps to the real length).
        // AXStringForRange works but errors past the end, so binary-search the length.
        var lo = 0, hi = 20000
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            var r = CFRange(location: 0, length: mid)
            if let t = string(el, range: &r), (t as NSString).length > 0 { lo = (t as NSString).length >= mid ? mid : (t as NSString).length; if (t as NSString).length < mid { break } }
            else { hi = mid - 1 }
        }
        return lo
    }

    /// Find the character whose bounds contain `point`, assuming characters are laid out in
    /// reading order (top-to-bottom lines, left-to-right). Binary search, then a short local scan.
    public static func indexForPoint(_ point: CGPoint, count: Int, bounds: (Int) -> CGRect?) -> Int? {
        func before(_ r: CGRect) -> Bool {   // character lies entirely before the point
            if r.maxY <= point.y { return true }
            if r.minY > point.y { return false }
            return r.maxX <= point.x
        }
        var lo = 0, hi = count - 1, probes = 0
        while lo < hi, probes < 64 {
            probes += 1
            let mid = (lo + hi) / 2
            var m = mid
            var b = bounds(m)
            while b == nil, m < hi { m += 1; b = bounds(m) }   // skip invisible chars (newlines)
            guard let r = b else { hi = mid; continue }
            if r.contains(point) { return m }
            if before(r) { lo = m + 1 } else { hi = mid }
        }
        for i in max(0, lo - 2)...min(count - 1, lo + 2) {
            if let r = bounds(i), r.insetBy(dx: -1, dy: -1).contains(point) { return i }
        }
        return nil
    }

    static func string(_ el: AXUIElement, range: inout CFRange) -> String? {
        guard let rv = AXValueCreate(.cfRange, &range) else { return nil }
        return param(el, kAXStringForRangeParameterizedAttribute, rv) as? String
    }

    /// Expand a UTF-16 offset in `text` to the surrounding word and sentence.
    public static func word(in text: String, at utf16Offset: Int) -> Result? {
        wordRange(in: text, at: utf16Offset).map { Result(word: $0.word, context: $0.context, axBounds: nil, method: "text", app: "") }
    }

    static func wordRange(in text: String, at utf16Offset: Int) -> (word: String, range: NSRange, context: String?)? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let off = min(max(0, utf16Offset), ns.length - 1)
        guard let r = tokenRange(in: text, at: off) else { return nil }
        let w = ns.substring(with: r)
        var sentence: String?
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .bySentences) { sub, sr, _, stop in
            if NSLocationInRange(off, sr) { sentence = sub?.trimmingCharacters(in: .whitespacesAndNewlines); stop.pointee = true }
        }
        return (w, r, sentence)
    }

    /// Word boundaries via CFStringTokenizer with the text's own language, so Chinese is
    /// segmented into words (还有 / 好消息) rather than whole runs or single characters.
    public static func tokenRange(in text: String, at utf16Offset: Int) -> NSRange? {
        let cf = text as CFString
        let len = CFStringGetLength(cf)
        guard len > 0 else { return nil }
        let off = min(max(0, utf16Offset), len - 1)
        let whole = CFRange(location: 0, length: len)
        let lang = CFStringTokenizerCopyBestStringLanguage(cf, whole) as String?
        let locale = CFLocaleCreate(nil, CFLocaleIdentifier((lang ?? "en") as CFString))
        let tok = CFStringTokenizerCreate(nil, cf, whole, kCFStringTokenizerUnitWordBoundary, locale)
        for probe in [off, off - 1] where probe >= 0 {
            CFStringTokenizerGoToTokenAtIndex(tok, probe)
            let r = CFStringTokenizerGetCurrentTokenRange(tok)
            guard r.location != kCFNotFound, r.length > 0 else { continue }
            let ns = NSRange(location: r.location, length: r.length)
            let t = (text as NSString).substring(with: ns)
            if t.unicodeScalars.contains(where: { CharacterSet.letters.union(.decimalDigits).contains($0) }) { return ns }
        }
        return nil
    }

    // MARK: - Helpers

    static func role(_ el: AXUIElement) -> String? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v) == .success ? v as? String : nil
    }

    static func parent(_ el: AXUIElement) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &v) == .success, let v else { return nil }
        return (v as! AXUIElement)
    }

    static func isInsideLink(_ el: AXUIElement) -> Bool {
        var e: AXUIElement? = el
        for _ in 0..<6 {
            guard let x = e else { return false }
            if role(x) == "AXLink" { return true }
            e = parent(x)
        }
        return false
    }

    static func focusedSelectedText() -> String? {
        let sys = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused else { return nil }
        var sel: CFTypeRef?
        guard AXUIElementCopyAttributeValue(f as! AXUIElement, kAXSelectedTextAttribute as CFString, &sel) == .success else { return nil }
        let s = (sel as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty || s.count > 80 ? nil : s
    }

    /// Existing selection, else (not over links/controls) double-click to select the word and read it back.
    static func selectionFallback(app: String, point: CGPoint, element: AXUIElement?) -> Result? {
        if let s = focusedSelectedText() {
            return Result(word: s, context: nil, axBounds: nil, method: "selection", app: app)
        }
        if let el = element {
            let r = role(el) ?? ""
            if isInsideLink(el) || ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuItem", "AXImage"].contains(r) {
                VocabLog.log("AX: skip double-click fallback over \(r)")
                return nil
            }
        }
        doubleClick(at: point)
        Thread.sleep(forTimeInterval: 0.12)
        if let s = focusedSelectedText() {
            return Result(word: s, context: nil, axBounds: nil, method: "doubleClick", app: app)
        }
        if let s = copySelectionPreservingPasteboard() {
            return Result(word: s, context: nil, axBounds: nil, method: "doubleClick+copy", app: app)
        }
        return nil
    }

    static func doubleClick(at axPt: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        for click in 1...2 {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: axPt, mouseButton: .left)
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                e?.post(tap: .cghidEventTap)
            }
        }
    }

    /// ⌘C round-trip that restores the previous pasteboard contents.
    static func copySelectionPreservingPasteboard() -> String? {
        let pb = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        }
        let before = pb.changeCount
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
        var text: String?
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.03)
            if pb.changeCount != before { text = pb.string(forType: .string); break }
        }
        if pb.changeCount != before {
            pb.clearContents()
            let items = saved.map { d -> NSPasteboardItem in
                let it = NSPasteboardItem(); for (t, v) in d { it.setData(v, forType: t) }; return it
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
        let s = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty || s.count > 80 ? nil : s
    }
}
