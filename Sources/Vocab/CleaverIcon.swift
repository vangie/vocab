import AppKit
import SwiftUI

/// 斩: a cleaver (菜刀) drawn as a template image — this macOS has no knife/sword SF Symbol.
/// Drawn on SF Symbols' 16 pt grid with ~1.5 pt strokes so it sits with the symbols beside it
/// and tints like them (sidebar accent, button label colour).
enum CleaverIcon {
    static func image(size: CGFloat = 16) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { r in
            let s = r.width / 16
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * s, y: y * s) }
            NSColor.black.setStroke(); NSColor.black.setFill()
            // Drawn horizontally, then rotated 45° so the blade reads as a cleaver at 16–17 pt
            // (a level blade + handle looked like a mug). Blade upper-left, handle lower-right.
            let t = NSAffineTransform()
            t.translateX(by: 8 * s, yBy: 8 * s); t.rotate(byDegrees: 45); t.translateX(by: -8 * s, yBy: -8 * s)
            t.concat()
            // Wide rectangular blade (outlined, SF-like 1.5 pt), with a filled spine band.
            let blade = NSBezierPath(roundedRect: NSRect(x: 0.9 * s, y: 4.0 * s, width: 8.6 * s, height: 6.6 * s), xRadius: 1.0 * s, yRadius: 1.0 * s)
            blade.lineWidth = 1.5 * s; blade.lineJoinStyle = .round
            blade.stroke()
            NSBezierPath(rect: NSRect(x: 0.9 * s, y: 4.0 * s, width: 8.6 * s, height: 2.0 * s)).fill()
            // Bolster + distinct handle, narrower than the blade.
            NSBezierPath(rect: NSRect(x: 9.5 * s, y: 4.6 * s, width: 1.0 * s, height: 2.8 * s)).fill()
            let handle = NSBezierPath(roundedRect: NSRect(x: 11.2 * s, y: 4.75 * s, width: 4.4 * s, height: 2.5 * s),
                                      xRadius: 1.25 * s, yRadius: 1.25 * s)
            handle.fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "斩"
        return img
    }

    static var swiftUI: Image { Image(nsImage: image()).renderingMode(.template) }
}
