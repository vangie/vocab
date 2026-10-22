import ApplicationServices
import CMultitouch
import CoreGraphics
import Foundation

/// With tap-to-click on and the system three-finger Look Up gesture taken over, macOS turns
/// the three-finger tap into an ordinary click, which activates links under the pointer.
/// This event tap swallows mouse-down/up pairs that arrive while (or just after) three
/// fingers were touching the trackpad. Physical clicks at other times pass through untouched.
///
/// Swallowing needs an active (default) tap, and an active tap sits in every click's path, so:
/// - it runs on its own thread's run loop (a busy main thread can never stall clicks);
/// - the callback only reads a timestamp and a small set; logging is dispatched off the tap thread;
/// - it lives only while Accessibility is granted: a 1 s poll (non-prompting AXIsProcessTrusted) plus
///   the com.apple.accessibility.api notification tear it down the moment trust is revoked and
///   re-create it when trust returns;
/// - a tap disabled by timeout/user input is re-enabled only while trusted, else torn down.
/// (Before: on the main run loop and re-enabled unconditionally — after the user revoked
/// Accessibility the WindowServer kept waiting on it and every click system-wide stopped.)
public final class ClickSuppressor: @unchecked Sendable {
    public static let shared = ClickSuppressor()
    /// Window after the last three-finger contact in which a click counts as part of the tap.
    public var window: Double = 0.25

    private let lock = NSLock()
    private var wanted = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tapLoop: CFRunLoop?
    private var swallowing: Set<Int64> = []   // event types whose matching "up" we must drop (tap thread)
    private var monitor: Timer?
    private var axObserver: NSObjectProtocol?

    /// Overridable for tests.
    public var isTrusted: () -> Bool = { AXIsProcessTrusted() }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return tap != nil }

    /// Pure decision function (unit-tested).
    public static func shouldSuppress(secondsSinceThreeTouch: Double, window: Double) -> Bool {
        secondsSinceThreeTouch >= 0 && secondsSinceThreeTouch <= window
    }

    /// What to do when the system disables the tap (pure, unit-tested).
    public enum DisabledAction: Equatable { case reenable, teardown }
    public static func onDisabled(trusted: Bool) -> DisabledAction { trusted ? .reenable : .teardown }

    /// Want the suppressor on; it is installed whenever Accessibility is granted. Call on the main thread.
    @discardableResult
    public func start() -> Bool {
        wanted = true
        startMonitoring()
        return sync()
    }

    /// Off for good (until `start`). Call on the main thread.
    public func stop() {
        wanted = false
        monitor?.invalidate(); monitor = nil
        if let o = axObserver { DistributedNotificationCenter.default().removeObserver(o); axObserver = nil }
        uninstall(reason: "stopped")
    }

    /// Install/remove the tap to match `wanted && trusted`. Returns whether it is installed.
    @discardableResult
    public func sync() -> Bool {
        let trusted = isTrusted()
        if wanted && trusted { return install() }
        if isRunning { uninstall(reason: trusted ? "stopped" : "Accessibility revoked") }
        return false
    }

    private func startMonitoring() {
        guard monitor == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.sync() }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        monitor = t
        axObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            // The trust change lands a moment after the notification.
            self?.sync()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.sync() }
        }
    }

    private func install() -> Bool {
        lock.lock()
        if tap != nil { lock.unlock(); return true }
        lock.unlock()
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: { _, type, event, _ in
            ClickSuppressor.shared.handle(type, event)
        }, userInfo: nil) else {
            VocabLog.log("click suppressor: event tap could not be created")
            return false
        }
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, src, .commonModes)
            self?.lock.lock(); self?.tapLoop = loop; self?.lock.unlock()
            ready.signal()
            CFRunLoopRun()   // returns after uninstall() stops it
        }
        thread.name = "Vocab click suppressor"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        lock.lock(); tap = t; source = src; lock.unlock()
        CGEvent.tapEnable(tap: t, enable: true)
        VocabLog.log("click suppressor: started")
        return true
    }

    private func uninstall(reason: String) {
        lock.lock()
        let t = tap, s = source, loop = tapLoop
        tap = nil; source = nil; tapLoop = nil
        lock.unlock()
        guard let t else { return }
        CGEvent.tapEnable(tap: t, enable: false)
        if let s, let loop { CFRunLoopRemoveSource(loop, s, .commonModes); CFRunLoopStop(loop) }
        CFMachPortInvalidate(t)
        VocabLog.log("click suppressor: removed (\(reason))")
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            swallowing = []
            if Self.onDisabled(trusted: isTrusted()) == .reenable {
                lock.lock(); let t = tap; lock.unlock()
                if let t { CGEvent.tapEnable(tap: t, enable: true) }
            } else {
                DispatchQueue.main.async { self.uninstall(reason: "disabled while untrusted") }
            }
            return Unmanaged.passUnretained(event)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Synthetic events we post ourselves are left alone.
            if event.getIntegerValueField(.eventSourceUserData) == ClickSuppressor.ownMarker { return Unmanaged.passUnretained(event) }
            let dt = vmt_seconds_since_three_touch()
            if ClickSuppressor.shouldSuppress(secondsSinceThreeTouch: dt, window: window) {
                swallowing.insert(Int64(type.rawValue + 1))   // matching up event type
                let raw = type.rawValue
                DispatchQueue.global(qos: .utility).async {
                    VocabLog.log("click suppressor: swallowed \(raw) \(String(format: "%.3f", dt))s after three-finger contact")
                }
                return nil
            }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if swallowing.remove(Int64(type.rawValue)) != nil { return nil }
        default: break
        }
        return Unmanaged.passUnretained(event)
    }

    /// Marker set on events Vocab posts itself (double-click fallback) so they are not swallowed.
    public static let ownMarker: Int64 = 0x564F4341   // "VOCA"
}
