import AppKit

/// Composes a pseudo-character from two real characters rendered at the same size, so stroke weight,
/// height and radical form (礻 as in 祥, not a squeezed 示) match real glyphs. Each donor is split into
/// its left and right components by connected ink regions (whole strokes, never cut), then the left
/// component of one donor and the right component of the other are placed with the left donor's own spacing.
enum PseudoHanziGlyph {
    struct Raster { var w: Int; var a: [UInt8] }   // alpha, row 0 = top

    static func raster(_ ch: String, px: Int, font: NSFont) -> Raster? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 1, hasAlpha: false, isPlanar: false,
                                         colorSpaceName: .deviceWhite, bytesPerRow: px, bitsPerPixel: 8),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: px, height: px).fill()
        let f = NSFont(descriptor: font.fontDescriptor, size: CGFloat(px) * 0.9) ?? font
        let s = NSAttributedString(string: ch, attributes: [.font: f, .foregroundColor: NSColor.black])
        let sz = s.size()
        s.draw(at: NSPoint(x: (CGFloat(px) - sz.width) / 2, y: (CGFloat(px) - sz.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        guard let d = rep.bitmapData else { return nil }
        return Raster(w: px, a: (0..<px * px).map { 255 - d[$0] })
    }

    /// Splits into (left, right) by connected regions whose centre lies left/right of the lightest
    /// column in 20–60%. Nil when one region straddles the split (components touch).
    static func split(_ r: Raster) -> (left: Raster, right: Raster, gap: Int)? {
        let w = r.w
        var ink = [Int](repeating: 0, count: w)
        for y in 0..<w { for x in 0..<w where r.a[y * w + x] > 96 { ink[x] += 1 } }
        let lo = w * 20 / 100, hi = w * 60 / 100
        let cut = (lo...hi).min { ink[$0] < ink[$1] }!
        var label = [Int](repeating: -1, count: w * w)
        var left = Raster(w: w, a: .init(repeating: 0, count: w * w)), right = left
        var lMax = -1, rMin = w
        for start in 0..<(w * w) where r.a[start] > 40 && label[start] < 0 {
            var stack = [start], pix: [Int] = []
            label[start] = 0
            var minX = w, maxX = 0, sumX = 0
            while let p = stack.popLast() {
                pix.append(p); let x = p % w, y = p / w
                minX = min(minX, x); maxX = max(maxX, x); sumX += x
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < w else { continue }
                    let q = ny * w + nx
                    if label[q] < 0 && r.a[q] > 40 { label[q] = 0; stack.append(q) }
                }
            }
            let isLeft = sumX / pix.count < cut
            // A big region spanning well past the cut on both sides means the components are joined.
            if pix.count > w && minX < cut - w / 10 && maxX > cut + w / 10 { return nil }
            for p in pix { if isLeft { left.a[p] = r.a[p] } else { right.a[p] = r.a[p] } }
            if isLeft { lMax = max(lMax, maxX) } else { rMin = min(rMin, minX) }
        }
        guard lMax >= 0, rMin < w else { return nil }
        return (left, right, rMin - lMax)
    }

    /// Template image of left-of-a-left-donor + right-of-a-right-donor (each a string of candidates).
    static func image(leftDonors: String, rightDonors: String, size: CGFloat, font: NSFont) -> NSImage? {
        let px = 160   // fixed raster so the split (and scripts/filter-pseudohanzi.swift) doesn't depend on display size
        func first(_ s: String) -> (left: Raster, right: Raster, gap: Int)? {
            for c in s { if let r = raster(String(c), px: px, font: font), let sp = split(r) { return sp } }
            return nil
        }
        guard let L = first(leftDonors), let R = first(rightDonors) else { return nil }
        let w = px
        func cols(_ r: Raster) -> (Int, Int) {
            var lo = w, hi = -1
            for y in 0..<w { for x in 0..<w where r.a[y * w + x] > 0 { lo = min(lo, x); hi = max(hi, x) } }
            return (lo, hi)
        }
        let (l0, l1) = cols(L.left), (r0, r1) = cols(R.right)
        let shift = (l1 + L.gap) - r0                         // right part starts where the left donor's did
        let total0 = l0, total1 = r1 + shift
        let dx = (w - (total1 - total0 + 1)) / 2 - total0     // recentre
        var out = [UInt8](repeating: 0, count: w * w)
        for y in 0..<w { for x in 0..<w {
            let la = L.left.a[y * w + x]; if la > 0, (0..<w).contains(x + dx) { out[y * w + x + dx] = max(out[y * w + x + dx], la) }
            let ra = R.right.a[y * w + x]; let nx = x + shift + dx
            if ra > 0, (0..<w).contains(nx) { out[y * w + nx] = max(out[y * w + nx], ra) }
        } }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: w, bitsPerSample: 8,
                                         samplesPerPixel: 2, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceWhite, bytesPerRow: w * 2, bitsPerPixel: 16),
              let d = rep.bitmapData else { return nil }
        for i in 0..<(w * w) { d[2 * i] = 0; d[2 * i + 1] = out[i] }
        rep.size = NSSize(width: size, height: size)
        let img = NSImage(size: rep.size); img.addRepresentation(rep)
        img.isTemplate = true
        return img
    }
}
