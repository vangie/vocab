import Foundation

/// Per-dictionary display preferences, as defined by the dictionary bundle:
///   - DCSDictionaryDefaultPrefs (Info.plist): keys and default values,
///   - DCSDictionaryPrefsHTML: the settings form shown by Dictionary.app,
///   - Dictionary.app's current choices: com.apple.DictionaryServices › DCSDictionaryPrefs › <bundle id>.
/// Vocab never writes Apple's domain. Changes made in Vocab are kept in Vocab's own defaults
/// and applied by re-running the dictionary's XSL with those values as parameters.
public struct DictionaryPrefs: Sendable {
    public static let defaultsKey = "VocabDictionaryPrefs"

    public let bundleID: String
    public let info: [String: Any]
    public let bundleURL: URL

    public init?(bundleURL: URL?) {
        guard let url = bundleURL,
              let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else { return nil }
        self.bundleURL = url
        self.info = info
        self.bundleID = info["CFBundleIdentifier"] as? String ?? url.deletingPathExtension().lastPathComponent
    }

    var resources: URL { bundleURL.appendingPathComponent("Contents/Resources") }

    public var prefsHTML: URL? {
        (info["DCSDictionaryPrefsHTML"] as? String).map { resources.appendingPathComponent($0) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }
    public var xsl: URL? {
        (info["DCSDictionaryXSL"] as? String).map { resources.appendingPathComponent($0) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }
    /// Info.plist strings sometimes carry markup («…<br/>…»): line breaks for <br>, other tags dropped.
    public static func plainText(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (e, c) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&copy;", "©")] {
            t = t.replacingOccurrences(of: e, with: c)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var copyright: String? { (info["DCSDictionaryCopyright"] ?? info["NSHumanReadableCopyright"]) as? String }
    public var manufacturer: String? { info["DCSDictionaryManufacturerName"] as? String }
    public var version: String? { (info["CFBundleShortVersionString"] ?? info["CFBundleVersion"]) as? String }
    public var languages: [String] {
        guard let langs = info["DCSDictionaryLanguages"] as? [[String: Any]] else { return [] }
        var out: [String] = []
        for l in langs {
            for k in ["DCSDictionaryIndexLanguage", "DCSDictionaryDescriptionLanguage"] {
                if let v = l[k] as? String, !out.contains(v) { out.append(v) }
            }
        }
        return out
    }

    public var defaults: [String: String] { Self.strings(info["DCSDictionaryDefaultPrefs"]) }

    /// Dictionary.app's current values (read-only for us).
    public var applePrefs: [String: String] {
        let all = CFPreferencesCopyAppValue("DCSDictionaryPrefs" as CFString, "com.apple.DictionaryServices" as CFString) as? [String: Any]
        return Self.strings(all?[bundleID])
    }

    /// What DictionaryServices itself applies when it renders (defaults overlaid with Apple's values).
    public var systemEffective: [String: String] { defaults.merging(applePrefs) { _, b in b } }

    public func vocabOverrides(_ store: UserDefaults = .standard) -> [String: String] {
        Self.strings((store.dictionary(forKey: Self.defaultsKey))?[bundleID])
    }

    public func effective(_ store: UserDefaults = .standard) -> [String: String] {
        systemEffective.merging(vocabOverrides(store)) { _, b in b }
    }

    /// True when Vocab must re-run the XSL itself because its values differ from the system's.
    public func needsOwnTransform(_ store: UserDefaults = .standard) -> Bool {
        xsl != nil && effective(store) != systemEffective
    }

    public func save(_ values: [String: String], _ store: UserDefaults = .standard) {
        var all = store.dictionary(forKey: Self.defaultsKey) ?? [:]
        // Store only what differs from the system values, so Dictionary.app changes still flow through.
        let diff = values.filter { systemEffective[$0.key] != $0.value }
        if diff.isEmpty { all.removeValue(forKey: bundleID) } else { all[bundleID] = diff }
        store.set(all, forKey: Self.defaultsKey)
    }

    public func reset(_ store: UserDefaults = .standard) {
        var all = store.dictionary(forKey: Self.defaultsKey) ?? [:]
        all.removeValue(forKey: bundleID)
        store.set(all, forKey: Self.defaultsKey)
    }

    static func strings(_ any: Any?) -> [String: String] {
        guard let d = any as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in d { out[k] = "\(v)" }
        return out
    }

    // MARK: - XSL

    /// Apply the dictionary's XSL to a raw record (DCSRecordCopyData version 0) with `params`.
    /// Returns the transformed XHTML, or nil on failure.
    public func transform(rawXML: String, params: [String: String]) -> String? {
        guard let xsl else { return nil }
        // The XHTML 1.1 DOCTYPE makes the parser fetch DTDs from w3.org; drop it.
        let xml = rawXML.replacingOccurrences(of: #"<!DOCTYPE[^>]*>"#, with: "", options: .regularExpression)
        guard let doc = try? XMLDocument(xmlString: xml, options: []) else { return nil }
        // XSLT parameters are XPath expressions: quote them as string literals.
        var args: [String: String] = [:]
        for (k, v) in params { args[k] = v.contains("'") ? "\"\(v)\"" : "'\(v)'" }
        guard let out = try? doc.objectByApplyingXSLT(at: xsl, arguments: args) else { return nil }
        if let d = out as? XMLDocument { return d.xmlString }
        if let d = out as? Data { return String(data: d, encoding: .utf8) }
        return nil
    }

    /// Replace the <body> of `rendered` (DictionaryServices output with CSS inlined in <head>)
    /// with the <body> of `transformed`.
    public static func splice(rendered: String, transformed: String) -> String? {
        func body(_ s: String) -> Range<String.Index>? {
            guard let a = s.range(of: "<body", options: .caseInsensitive),
                  let b = s.range(of: "</body>", options: [.caseInsensitive, .backwards]) else { return nil }
            return a.lowerBound..<b.upperBound
        }
        guard let rb = body(rendered), let tb = body(transformed) else { return nil }
        var s = rendered
        s.replaceSubrange(rb, with: transformed[tb])
        return s
    }
}
