import Foundation

/// A dictionary known to the system's DictionaryServices.
public struct DictionaryInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let shortName: String
    public let bundleURL: URL?
}

/// One record returned by a dictionary for a search string.
public struct DictionaryEntry: Identifiable, Sendable {
    public let id: String
    public let dictionary: DictionaryInfo
    public let headword: String
    /// Full XHTML as Dictionary.app renders it (CSS inlined, XSL applied).
    public let html: String
    /// Compact "panel" variant used by Look Up.
    public let panelHTML: String
    /// Plain text rendering.
    public let plainText: String
    /// Folder that relative URLs in the entry (audio, images) resolve against.
    public let resourceDirectory: URL?

    public init(id: String, dictionary: DictionaryInfo, headword: String, html: String, panelHTML: String,
                plainText: String, resourceDirectory: URL?) {
        self.id = id; self.dictionary = dictionary; self.headword = headword; self.html = html
        self.panelHTML = panelHTML; self.plainText = plainText; self.resourceDirectory = resourceDirectory
    }

    /// A short one-line snippet suitable for the wordbook.
    public var snippet: String { DictionaryEntry.makeSnippet(plainText, headword: headword) }

    public static func makeSnippet(_ text: String, headword: String, limit: Int = 160) -> String {
        var s = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > limit { s = String(s.prefix(limit)) + "…" }
        return s
    }
}

/// Swift wrapper around the private DCS* functions in DictionaryServices.framework.
/// All symbols are resolved with dlsym so a missing symbol degrades gracefully.
public final class DictionaryService: @unchecked Sendable {
    public static let shared = DictionaryService()

    private typealias FArray = @convention(c) () -> Unmanaged<CFArray>?
    private typealias FSet = @convention(c) () -> Unmanaged<CFSet>?
    private typealias FString = @convention(c) (CFTypeRef) -> Unmanaged<CFString>?
    private typealias FURL = @convention(c) (CFTypeRef) -> Unmanaged<CFURL>?
    private typealias FRecords = @convention(c) (CFTypeRef, CFString, UnsafeRawPointer?, UnsafeRawPointer?) -> Unmanaged<CFArray>?
    private typealias FData = @convention(c) (CFTypeRef, Int) -> Unmanaged<CFString>?

    private let handle: UnsafeMutableRawPointer?
    private let queue = DispatchQueue(label: "vocab.dcs")
    private var refs: [String: CFTypeRef] = [:]
    private var infos: [String: DictionaryInfo] = [:]

    public var isAvailable: Bool { handle != nil && sym("DCSCopyRecordsForSearchString") != nil }

    private init() {
        handle = dlopen("/System/Library/Frameworks/CoreServices.framework/Frameworks/DictionaryServices.framework/DictionaryServices", RTLD_NOW)
    }

    private func sym(_ name: String) -> UnsafeMutableRawPointer? {
        guard let handle else { return nil }
        return dlsym(handle, name)
    }

    private func fn<T>(_ name: String, _ type: T.Type) -> T? {
        guard let p = sym(name) else { return nil }
        return unsafeBitCast(p, to: type)
    }

    private func info(for ref: CFTypeRef) -> DictionaryInfo {
        let name = fn("DCSDictionaryGetName", FString.self)?(ref)?.takeUnretainedValue() as String? ?? "?"
        let short = fn("DCSDictionaryGetShortName", FString.self)?(ref)?.takeUnretainedValue() as String? ?? name
        let ident = fn("DCSDictionaryGetIdentifier", FString.self)?(ref)?.takeUnretainedValue() as String? ?? name
        let url = fn("DCSDictionaryGetURL", FURL.self)?(ref)?.takeUnretainedValue() as URL?
        let i = DictionaryInfo(id: ident, name: name, shortName: short, bundleURL: url)
        refs[ident] = ref
        infos[ident] = i
        return i
    }

    /// Dictionaries enabled in Dictionary.app's settings, in its order.
    public func activeDictionaries() -> [DictionaryInfo] {
        queue.sync {
            guard let arr = fn("DCSGetActiveDictionaries", FArray.self)?()?.takeUnretainedValue() as [AnyObject]? else { return [] }
            return arr.map { info(for: $0) }
        }
    }

    /// Every dictionary installed (system assets plus ~/Library/Dictionaries), sorted by name.
    public func availableDictionaries() -> [DictionaryInfo] {
        queue.sync {
            guard let set = fn("DCSCopyAvailableDictionaries", FSet.self)?()?.takeRetainedValue() as? Set<NSObject> else { return [] }
            return set.map { info(for: $0) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    /// Look a word up in the given dictionaries (in order). Returns entries grouped in dictionary order.
    public func lookup(_ word: String, in dictionaries: [DictionaryInfo], maxPerDictionary: Int = 8) -> [DictionaryEntry] {
        let term = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        return queue.sync {
            guard let records = fn("DCSCopyRecordsForSearchString", FRecords.self),
                  let copyData = fn("DCSRecordCopyData", FData.self) else { return [] }
            let headwordFn = fn("DCSRecordGetHeadword", FString.self)
            var out: [DictionaryEntry] = []
            for d in dictionaries {
                guard let ref = refs[d.id] else { continue }
                guard let recs = records(ref, term as CFString, nil, nil)?.takeRetainedValue() as [AnyObject]? else { continue }
                for (i, r) in recs.prefix(maxPerDictionary).enumerated() {
                    let html = copyData(r, 1)?.takeRetainedValue() as String? ?? ""
                    let panel = copyData(r, 2)?.takeRetainedValue() as String? ?? html
                    let text = copyData(r, 3)?.takeRetainedValue() as String? ?? ""
                    let hw = headwordFn?(r)?.takeUnretainedValue() as String? ?? term
                    out.append(DictionaryEntry(
                        id: "\(d.id)#\(i)#\(hw)",
                        dictionary: d, headword: hw, html: html, panelHTML: panel, plainText: text,
                        resourceDirectory: EntryHTML.resourceDirectory(fromHTML: html, bundleURL: d.bundleURL)))
                }
            }
            return out
        }
    }

    /// Paths of dictionary bundles we have seen; used to restrict which files the web view may load.
    public func knownBundlePaths() -> [String] {
        queue.sync { infos.values.compactMap { $0.bundleURL?.resolvingSymlinksInPath().path } }
    }
}
