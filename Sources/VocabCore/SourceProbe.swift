import AppKit
import ApplicationServices
import NaturalLanguage

public enum Lemmatizer {
    /// Base form of `word` (NLTagger lemma, in its sentence when given); nil if unknown or the same.
    public static func lemma(of word: String, in sentence: String? = nil) -> String? {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, w.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
        var text = w; var range = text.startIndex..<text.endIndex
        if let s = sentence, let r = s.range(of: w, options: [.caseInsensitive]) { text = s; range = r }
        let t = NLTagger(tagSchemes: [.lemma]); t.string = text
        var out: String?
        t.enumerateTags(in: range, unit: .word, scheme: .lemma, options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
            out = tag?.rawValue; return false
        }
        guard let l = out?.lowercased(), l != w.lowercased() else { return nil }
        return l
    }
}

/// Where a looked-up word came from: the app, and for browsers the page URL and title.
public enum SourceProbe {
    static let browsers: [String: String] = [
        "com.apple.Safari": "Safari", "com.apple.SafariTechnologyPreview": "Safari Technology Preview",
        "com.google.Chrome": "Google Chrome", "com.google.Chrome.canary": "Google Chrome Canary",
        "com.microsoft.edgemac": "Microsoft Edge", "com.brave.Browser": "Brave Browser", "company.thebrowser.Browser": "Arc",
    ]

    /// Probe the app at an AX (top-left origin) point. AX first (AXWebArea's AXURL, the window
    /// title); AppleScript for Safari/Chrome-family only when AX gives no URL.
    public static func source(atAXPoint pt: CGPoint) -> WordSource {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.3)
        var elRef: AXUIElement?
        AXUIElementCopyElementAtPosition(sys, Float(pt.x), Float(pt.y), &elRef)
        var pid: pid_t = 0
        if let el = elRef { AXUIElementGetPid(el, &pid) }
        let app = pid != 0 ? NSRunningApplication(processIdentifier: pid) : NSWorkspace.shared.frontmostApplication
        var src = WordSource(app: app?.localizedName)
        guard let el = elRef else { return src }
        var cur: AXUIElement? = el
        for _ in 0..<40 {
            guard let c = cur else { break }
            let role = attr(c, kAXRoleAttribute) as? String
            if role == "AXWebArea" {
                if let u = attr(c, kAXURLAttribute) as? URL { src.url = u.absoluteString }
                else if let s = attr(c, kAXURLAttribute) as? String { src.url = s }
                if src.title == nil, let t = attr(c, kAXTitleAttribute) as? String, !t.isEmpty { src.title = t }
            }
            if role == "AXWindow" {
                if src.title == nil, let t = attr(c, kAXTitleAttribute) as? String, !t.isEmpty { src.title = t }
                break
            }
            cur = attr(c, kAXParentAttribute).map { $0 as! AXUIElement }
        }
        if src.url == nil, let id = app?.bundleIdentifier, browsers[id] != nil, let r = appleScriptURL(bundleID: id) {
            src.url = r.url; if r.title != nil { src.title = r.title }
        }
        if let u = src.url, !(u.hasPrefix("http") || u.hasPrefix("file")) { src.url = nil }
        if src.url == nil, src.title == app?.localizedName { src.title = nil }
        return src
    }

    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    static func appleScriptURL(bundleID: String) -> (url: String, title: String?)? {
        let script = bundleID.hasPrefix("com.apple.Safari")
            ? "tell application id \"\(bundleID)\" to return {URL, name} of front document"
            : "tell application id \"\(bundleID)\" to return {URL, title} of active tab of front window"
        var err: NSDictionary?
        guard let d = NSAppleScript(source: script)?.executeAndReturnError(&err), d.numberOfItems >= 1,
              let u = d.atIndex(1)?.stringValue else { return nil }
        return (u, d.numberOfItems >= 2 ? d.atIndex(2)?.stringValue : nil)
    }
}
