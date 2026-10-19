import CMultitouch
import Foundation

/// Global three-finger tap detection via the private MultitouchSupport framework.
public final class ThreeFingerMonitor: @unchecked Sendable {
    public static let shared = ThreeFingerMonitor()
    public var onTap: (() -> Void)?
    public private(set) var deviceCount = 0
    public private(set) var lastTap: Date?
    public var isRunning: Bool { deviceCount > 0 }
    public var frameCount: Int { Int(vmt_frame_count()) }

    /// Log finger-count changes to ~/Library/Logs/Vocab/vocab.log.
    public var verbose = true {
        didSet { vmt_set_frame_logger(verbose ? ThreeFingerMonitor.frameLogger : nil) }
    }

    static let frameLogger: vmt_frame_logger = { total, active, states, ts in
        var s: [Int32] = []
        if let states { for i in 0..<Int(min(total, 16)) { s.append(states[i]) } }
        VocabLog.log("touch frame: contacts=\(total) touching=\(active) states=\(s) t=\(String(format: "%.3f", ts))")
    }

    /// Returns the number of multitouch devices started (-1 if the framework is unavailable).
    @discardableResult
    public func start() -> Int {
        vmt_set_frame_logger(verbose ? ThreeFingerMonitor.frameLogger : nil)
        let n = Int(vmt_start {
            DispatchQueue.main.async {
                ThreeFingerMonitor.shared.lastTap = Date()
                VocabLog.log("three-finger tap detected")
                ThreeFingerMonitor.shared.onTap?()
            }
        })
        deviceCount = max(0, n)
        VocabLog.log("multitouch start: devices=\(n)")
        return n
    }

    public func stop() {
        vmt_stop()
        deviceCount = 0
        VocabLog.log("multitouch stop")
    }
}
