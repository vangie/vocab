import CMultitouch
import CoreGraphics
import Foundation

/// With tap-to-click on and the system three-finger Look Up gesture taken over, macOS turns
/// the three-finger tap into an ordinary click, which activates links under the pointer.
/// This event tap swallows mouse-down/up pairs that arrive while (or just after) three
/// fingers were touching the trackpad. Physical clicks at other times pass through untouched.
public final class ClickSuppressor: @unchecked Sendable {
    public static let shared = ClickSuppressor()
    /// Window after the last three-finger contact in which a click counts as part of the tap.
    public var window: Double = 0.25
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowing: Set<Int64> = []   // event types whose matching "up" we must drop

    public var isRunning: Bool { tap != nil }

    /// Pure decision function (unit-tested).
    public static func shouldSuppress(secondsSinceThreeTouch: Double, window: Double) -> Bool {
        secondsSinceThreeTouch >= 0 && secondsSinceThreeTouch <= window
    }

    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: { _, type, event, _ in
            ClickSuppressor.shared.handle(type, event)
        }, userInfo: nil) else {
            VocabLog.log("click suppressor: event tap could not be created")
            return false
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        VocabLog.log("click suppressor: started")
        return true
    }

    public func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil; swallowing = []
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Synthetic events we post ourselves (source state "private"/HID-less) are left alone.
            if event.getIntegerValueField(.eventSourceUserData) == ClickSuppressor.ownMarker { return Unmanaged.passUnretained(event) }
            let dt = vmt_seconds_since_three_touch()
            if ClickSuppressor.shouldSuppress(secondsSinceThreeTouch: dt, window: window) {
                swallowing.insert(Int64(type.rawValue + 1))   // matching up event type
                VocabLog.log("click suppressor: swallowed \(type.rawValue) \(String(format: "%.3f", dt))s after three-finger contact")
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
