import AppKit
import SwiftUI

/// Apple-Fitness-style concentric progress rings (self-contained, so it can be rendered offscreen
/// by scripts/render-rings.sh).
struct ActivityRings: View {
    let values: [Double]
    let colors: [Color]
    var lineWidth: CGFloat = 20
    var gap: CGFloat = 3
    var animated = true
    @State private var shown: [Double] = []

    var body: some View {
        ZStack {
            ForEach(values.indices, id: \.self) { i in
                Ring(value: animated ? (i < shown.count ? shown[i] : 0) : values[i], color: colors[i], lineWidth: lineWidth)
                    .padding(CGFloat(i) * (lineWidth + gap))
            }
        }
        .onAppear {
            guard animated else { return }
            shown = values.map { _ in 0 }
            withAnimation(.spring(response: 1.0, dampingFraction: 0.85).delay(0.1)) { shown = values }
        }
        .onChange(of: values) { _, v in withAnimation(.easeInOut(duration: 0.6)) { shown = v } }
    }
}

/// One ring. Progress t (in turns) runs clockwise from 12 o'clock.
/// - t ≤ 1: arc 0→t, gradient darker → full colour mapped onto the arc only; caps are drawn as separate
///   discs in their own colours, so no cap ever picks up the gradient's other end (no seam).
/// - t = 1: a seamless solid ring.
/// - t > 1: solid full ring, plus the last quarter turn up to the head drawn on top (full colour →
///   brighter), with a round head whose shadow falls back along the ring, like a lap passing over itself.
struct Ring: View, Animatable {
    var value: Double
    let color: Color
    let lineWidth: CGFloat
    var animatableData: Double { get { value } set { value = newValue } }

    static func shade(_ c: Color, _ f: CGFloat) -> Color {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)
        return Color(nsColor: (f < 0 ? n.blended(withFraction: -f, of: .black) : n.blended(withFraction: f, of: .white)) ?? n)
    }

    var body: some View {
        let t = max(0, min(value, 3))
        let c = color
        Canvas { ctx, size in
            let w = lineWidth
            let r = (min(size.width, size.height) - w) / 2
            let ctr = CGPoint(x: size.width / 2, y: size.height / 2)
            func angle(_ turns: Double) -> Angle { .degrees(-90 + 360 * turns) }
            func point(_ turns: Double) -> CGPoint {
                let a = 2 * Double.pi * turns
                return CGPoint(x: ctr.x + r * sin(a), y: ctr.y - r * cos(a))
            }
            func arc(_ from: Double, _ to: Double) -> Path {
                var p = Path(); p.addArc(center: ctr, radius: r, startAngle: angle(from), endAngle: angle(to), clockwise: false); return p
            }
            func disc(_ turns: Double) -> Path { let q = point(turns); return Path(ellipseIn: CGRect(x: q.x - w / 2, y: q.y - w / 2, width: w, height: w)) }
            let butt = StrokeStyle(lineWidth: w, lineCap: .butt)
            let full = Path(ellipseIn: CGRect(x: ctr.x - r, y: ctr.y - r, width: 2 * r, height: 2 * r))

            ctx.stroke(full, with: .color(c.opacity(0.18)), style: butt)                     // track
            if abs(t - 1) < 0.0005 { ctx.stroke(full, with: .color(c), style: butt); return }  // exactly full
            if t <= 0.002 { return }

            let headTurn: Double, tailTurn: Double, tailColor: Color, headColor: Color
            if t < 1 {
                ctx.stroke(arc(0, t), with: .conicGradient(Gradient(stops: [
                    .init(color: Self.shade(c, -0.25), location: 0), .init(color: c, location: t),
                ]), center: ctr, angle: angle(0)), style: butt)
                ctx.fill(disc(0), with: .color(Self.shade(c, -0.25)))   // start cap
                headTurn = t; tailTurn = 0; tailColor = Self.shade(c, -0.25); headColor = c
            } else {
                ctx.stroke(full, with: .color(c), style: butt)
                let start = t - 0.25
                headTurn = t; tailTurn = start; tailColor = c; headColor = Self.shade(c, 0.12)
                ctx.stroke(arc(start, t), with: .conicGradient(Gradient(stops: [
                    .init(color: c, location: 0), .init(color: headColor, location: 0.25),
                ]), center: ctr, angle: angle(start)), style: butt)
            }
            _ = tailTurn; _ = tailColor
            // Head: shadow cast backwards along the tangent, then the cap.
            let a = 2 * Double.pi * headTurn
            let back = CGSize(width: -cos(a) * w * 0.18, height: -sin(a) * w * 0.18)
            if t > 0.05 {
                ctx.drawLayer { l in
                    l.addFilter(.shadow(color: .black.opacity(t > 1 ? 0.5 : 0.3), radius: w * 0.14, x: back.width, y: back.height))
                    l.fill(disc(headTurn), with: .color(headColor))
                }
            } else {
                ctx.fill(disc(headTurn), with: .color(headColor))
            }
        }
    }
}
