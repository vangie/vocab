import SwiftUI
import AppKit

/// Pointing-hand cursor (+ optional hover callback) driven by an AppKit tracking area, so it also
/// works in the nonactivating lookup panel, where SwiftUI's .onHover / cursor push-pop don't fire
/// reliably. The tracking view never takes clicks (hitTest → nil).
private final class HandCursorNSView: NSView {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?
    private var inside = false
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate,
                                                      .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a); area = a
    }
    override func cursorUpdate(with e: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseEntered(with e: NSEvent) { inside = true; NSCursor.pointingHand.set(); onHover?(true) }
    override func mouseMoved(with e: NSEvent) { if inside { NSCursor.pointingHand.set() } }
    override func mouseExited(with e: NSEvent) { inside = false; NSCursor.arrow.set(); onHover?(false) }
    override func viewWillMove(toWindow w: NSWindow?) {
        if w == nil, inside { inside = false; NSCursor.arrow.set(); onHover?(false) }
        super.viewWillMove(toWindow: w)
    }
}

private struct HandCursorArea: NSViewRepresentable {
    var onHover: ((Bool) -> Void)?
    func makeNSView(context: Context) -> HandCursorNSView { let v = HandCursorNSView(); v.onHover = onHover; return v }
    func updateNSView(_ v: HandCursorNSView, context: Context) { v.onHover = onHover }
}

/// Hand cursor + a subtle rounded hover highlight, for clickable things that aren't system buttons.
private struct Clickable: ViewModifier {
    var highlight: Bool
    var radius: CGFloat
    var onHover: ((Bool) -> Void)?
    @State private var over = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.primary.opacity(highlight && over ? 0.08 : 0)))
            .overlay(HandCursorArea { h in over = h; onHover?(h) })
    }
}

extension View {
    /// Pointing hand on hover (works in nonactivating panels), optional hover highlight.
    func clickable(highlight: Bool = true, radius: CGFloat = 5, onHover: ((Bool) -> Void)? = nil) -> some View {
        modifier(Clickable(highlight: highlight, radius: radius, onHover: onHover))
    }
    /// Pointing hand only.
    func handCursor(onHover: ((Bool) -> Void)? = nil) -> some View {
        overlay(HandCursorArea(onHover: onHover))
    }
}
