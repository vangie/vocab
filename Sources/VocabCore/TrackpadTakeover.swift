import Foundation

/// Reads/writes a preference. The real implementation shells out to /usr/bin/defaults
/// (needed for -currentHost and other apps' domains); tests inject a fake.
public protocol PreferenceStore: AnyObject {
    func readInt(domain: String, key: String, currentHost: Bool) -> Int?
    func write(domain: String, key: String, currentHost: Bool, value: Int?)
    func activate()
}

/// "接管三指查词": turn off the system's "Look up & data detectors — Tap with three fingers"
/// while Vocab handles three-finger taps, remembering and restoring the original values.
public final class TrackpadTakeover {
    public struct Key: Hashable, Sendable {
        public let domain: String
        public let key: String
        public let currentHost: Bool
        var storageKey: String { "\(currentHost ? "host:" : "")\(domain)/\(key)" }
    }

    /// The keys System Settings writes for Trackpad ▸ Look up & data detectors ▸ Tap with three fingers.
    /// 2 = Look up on three-finger tap, 0 = off.
    public static let keys: [Key] = [
        Key(domain: "com.apple.AppleMultitouchTrackpad", key: "TrackpadThreeFingerTapGesture", currentHost: false),
        Key(domain: "com.apple.driver.AppleBluetoothMultitouch.trackpad", key: "TrackpadThreeFingerTapGesture", currentHost: false),
        Key(domain: "NSGlobalDomain", key: "com.apple.trackpad.threeFingerTapGesture", currentHost: true),
    ]

    static let savedKey = "TrackpadTakeover.saved"
    static let missing = -9999

    private let prefs: PreferenceStore
    private let defaults: UserDefaults

    public init(prefs: PreferenceStore = DefaultsCommandStore(), defaults: UserDefaults = .standard) {
        self.prefs = prefs
        self.defaults = defaults
    }

    /// True while Vocab holds saved originals, i.e. the system gesture is taken over.
    public var isEngaged: Bool { defaults.dictionary(forKey: Self.savedKey) != nil }

    /// Save the current values (once) and disable the system three-finger Look Up.
    public func engage() {
        if !isEngaged {
            var saved: [String: Int] = [:]
            for k in Self.keys {
                saved[k.storageKey] = prefs.readInt(domain: k.domain, key: k.key, currentHost: k.currentHost) ?? Self.missing
            }
            defaults.set(saved, forKey: Self.savedKey)
        }
        for k in Self.keys { prefs.write(domain: k.domain, key: k.key, currentHost: k.currentHost, value: 0) }
        prefs.activate()
    }

    /// Put the original values back (deleting keys that did not exist before).
    public func restore() {
        guard let saved = defaults.dictionary(forKey: Self.savedKey) as? [String: Int] else { return }
        for k in Self.keys {
            guard let v = saved[k.storageKey] else { continue }
            prefs.write(domain: k.domain, key: k.key, currentHost: k.currentHost, value: v == Self.missing ? nil : v)
        }
        prefs.activate()
        defaults.removeObject(forKey: Self.savedKey)
    }
}

/// PreferenceStore backed by /usr/bin/defaults.
public final class DefaultsCommandStore: PreferenceStore {
    public init() {}

    @discardableResult
    private func run(_ path: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func base(_ currentHost: Bool) -> [String] { currentHost ? ["-currentHost"] : [] }

    public func readInt(domain: String, key: String, currentHost: Bool) -> Int? {
        let (rc, out) = run("/usr/bin/defaults", base(currentHost) + ["read", domain, key])
        return rc == 0 ? Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
    }

    public func write(domain: String, key: String, currentHost: Bool, value: Int?) {
        if let value {
            run("/usr/bin/defaults", base(currentHost) + ["write", domain, key, "-int", "\(value)"])
        } else {
            run("/usr/bin/defaults", base(currentHost) + ["delete", domain, key])
        }
    }

    /// Ask the system to re-read trackpad preferences without a re-login.
    public func activate() {
        run("/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", ["-u"])
    }
}
