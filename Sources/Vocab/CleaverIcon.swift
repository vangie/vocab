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
            // Blade: square back edge at the top, slightly bellied cutting edge at the bottom.
            let blade = NSBezierPath()
            blade.move(to: p(1.6, 2.6))
            blade.line(to: p(10.4, 2.6))
            blade.line(to: p(10.4, 10.2))
            blade.curve(to: p(1.6, 9.4), controlPoint1: p(7.4, 11.4), controlPoint2: p(3.8, 10.8))
            blade.close()
            blade.lineWidth = 1.5 * s
            blade.lineJoinStyle = .round
            blade.stroke()
            // Hanging hole near the spine.
            NSBezierPath(ovalIn: NSRect(x: 3.0 * s, y: 4.1 * s, width: 1.8 * s, height: 1.8 * s)).fill()
            // Handle out to the right.
            let handle = NSBezierPath(roundedRect: NSRect(x: 10.4 * s, y: 3.6 * s, width: 4.4 * s, height: 2.6 * s),
                                      xRadius: 1.3 * s, yRadius: 1.3 * s)
            handle.fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "斩"
        return img
    }

    static var swiftUI: Image { Image(nsImage: image()).renderingMode(.template) }
}
