import AppKit
import SwiftUI

// Offscreen render of the 今日 rings at several progress values (light + dark) → PNGs.
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/rings"
let red = Color(red: 0.98, green: 0.07, blue: 0.31), green = Color(red: 0.25, green: 0.82, blue: 0.30), blue = Color(red: 0.0, green: 0.78, blue: 0.98)

@MainActor func render(_ dark: Bool) {
    let vals: [Double] = [0.3, 0.9, 1.0, 1.07, 1.4, 2.07]
    let v = HStack(spacing: 24) {
        ForEach(vals, id: \.self) { p in
            VStack(spacing: 6) {
                ActivityRings(values: [p, p, p], colors: [red, green, blue], animated: false).frame(width: 210, height: 210)
                Text(String(format: "%.0f%%", p * 100)).foregroundStyle(dark ? .white : .black)
            }
        }
    }
    .padding(24)
    .background(dark ? Color.black : Color.white)
    .environment(\.colorScheme, dark ? .dark : .light)
    let r = ImageRenderer(content: v); r.scale = 2
    guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { print("render failed"); return }
    let path = "\(out)/rings-\(dark ? "dark" : "light").png"
    try? png.write(to: URL(fileURLWithPath: path)); print(path)
}
@main struct RenderRings { @MainActor static func main() { try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true); render(false); render(true) } }
