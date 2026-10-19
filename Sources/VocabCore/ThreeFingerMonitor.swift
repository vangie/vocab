import CMultitouch
import Foundation

/// Global three-finger tap detection via the private MultitouchSupport framework.
public final class ThreeFingerMonitor: @unchecked Sendable {
    public static let shared = ThreeFingerMonitor()
    public var onTap: (() -> Void)?
    public private(set) var deviceCount = 0
    public var isRunning: Bool { deviceCount > 0 }

    /// Returns the number of multitouch devices started (-1 if the framework is unavailable).
    @discardableResult
    public func start() -> Int {
        let n = Int(vmt_start { DispatchQueue.main.async { ThreeFingerMonitor.shared.onTap?() } })
        deviceCount = max(0, n)
        return n
    }

    public func stop() {
        vmt_stop()
        deviceCount = 0
    }
}
