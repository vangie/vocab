import AppKit
import ApplicationServices

/// Finds the word under the mouse pointer through the Accessibility API.
public enum WordUnderCursor {
    public struct Result: Sendable { public let word: String; public let context: String? }

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt the first time.
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

    /// AX uses a top-left origin on the primary screen.
    static func axPoint(_ p: NSPoint) -> CGPoint {
        let h = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: p.x, y: h - p.y)
    }

    public static func current() -> Result? {
        guard isTrusted else { return nil }
        let pt = axPoint(NSEvent.mouseLocation)
        let sys = AXUIElementCreateSystemWide()
        var elRef: AXUIElement?
        if AXUIElementCopyElementAtPosition(sys, Float(pt.x), Float(pt.y), &elRef) == .success, let el = elRef,
           let r = wordAt(element: el, point: pt) {
            return r
        }
        return selectedText()
    }

    static func wordAt(element el: AXUIElement, point: CGPoint) -> Result? {
        var p = point
        guard let axPoint = AXValueCreate(.cgPoint, &p) else { return nil }
        var rangeVal: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXRangeForPositionParameterizedAttribute as CFString, axPoint, &rangeVal) == .success,
              let rv = rangeVal, CFGetTypeID(rv) == AXValueGetTypeID() else { return nil }
        var hit = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &hit), hit.location >= 0 else { return nil }
        // Fetch a window of text around the hit.
        let start = max(0, hit.location - 200)
        var window = CFRange(location: start, length: 400)
        var text = string(el, range: &window)
        if text == nil {
            window = CFRange(location: start, length: hit.location - start + 40)
            text = string(el, range: &window)
        }
        guard let t = text, !t.isEmpty else { return nil }
        return Self.word(in: t, at: hit.location - start)
    }

    static func string(_ el: AXUIElement, range: inout CFRange) -> String? {
        guard let rv = AXValueCreate(.cfRange, &range) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, rv, &out) == .success else { return nil }
        return out as? String
    }

    /// Expand a UTF-16 offset in `text` to the surrounding word and sentence.
    public static func word(in text: String, at utf16Offset: Int) -> Result? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let off = min(max(0, utf16Offset), ns.length - 1)
        var found: Result?
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { sub, r, _, stop in
            if NSLocationInRange(off, r), let sub {
                found = Result(word: sub, context: nil); stop.pointee = true
            }
        }
        guard let w = found else { return nil }
        var sentence: String?
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .bySentences) { sub, r, _, stop in
            if NSLocationInRange(off, r) { sentence = sub?.trimmingCharacters(in: .whitespacesAndNewlines); stop.pointee = true }
        }
        return Result(word: w.word, context: sentence)
    }

    static func selectedText() -> Result? {
        let sys = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused else { return nil }
        var sel: CFTypeRef?
        guard AXUIElementCopyAttributeValue(f as! AXUIElement, kAXSelectedTextAttribute as CFString, &sel) == .success,
              let s = (sel as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s.count < 80 else { return nil }
        return Result(word: s, context: nil)
    }
}
