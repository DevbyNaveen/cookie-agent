// Draws Cookie's app icon: the chocolate-chip pointer under the notch, on a graphite tile.
// Run: swift scripts/make-icon.swift <out.png>   (1024×1024; scripts/make-icon.sh builds the .icns)
import AppKit
import SwiftUI

/// The pointer's chip (same curve as ChipShape in Cookie/ClayCookie.swift).
struct Chip: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height, x = r.minX, y = r.minY
        var p = Path()
        p.move(to: CGPoint(x: x + 0.5 * w, y: y))
        p.addCurve(to: CGPoint(x: x + w, y: y + 0.72 * h),
                   control1: CGPoint(x: x + 0.64 * w, y: y + 0.3 * h), control2: CGPoint(x: x + w, y: y + 0.44 * h))
        p.addCurve(to: CGPoint(x: x, y: y + 0.72 * h),
                   control1: CGPoint(x: x + w, y: y + 1.07 * h), control2: CGPoint(x: x, y: y + 1.07 * h))
        p.addCurve(to: CGPoint(x: x + 0.5 * w, y: y),
                   control1: CGPoint(x: x, y: y + 0.44 * h), control2: CGPoint(x: x + 0.36 * w, y: y + 0.3 * h))
        p.closeSubpath()
        return p
    }
}

struct Icon: View {
    var body: some View {
        let tile = RoundedRectangle(cornerRadius: 186, style: .continuous)
        ZStack {
            // Graphite tile, lit from the top.
            tile.fill(LinearGradient(colors: [Color(white: 0.20), Color(white: 0.09)], startPoint: .top, endPoint: .bottom))
            tile.fill(RadialGradient(colors: [Color(red: 1, green: 0.72, blue: 0.45).opacity(0.22), .clear],
                                     center: UnitPoint(x: 0.5, y: 0.58), startRadius: 0, endRadius: 420))
            tile.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.03)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 3)
            // The notch Cookie lives in.
            UnevenRoundedRectangle(cornerRadii: .init(bottomLeading: 44, bottomTrailing: 44), style: .continuous)
                .fill(Color.black)
                .frame(width: 330, height: 78)
                .frame(maxHeight: .infinity, alignment: .top)
            // The chip pointer: clay chocolate, cream rim, tilted like a cursor.
            ZStack {
                Chip().fill(LinearGradient(colors: [Color(red: 0.62, green: 0.39, blue: 0.24), Color(red: 0.22, green: 0.11, blue: 0.05)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                Chip().stroke(Color(red: 1, green: 0.95, blue: 0.86), lineWidth: 26)
                // Clay sheen along the upper left of the chip.
                Ellipse().fill(Color.white.opacity(0.5)).frame(width: 46, height: 150)
                    .rotationEffect(.degrees(-12)).offset(x: -96, y: 30).blur(radius: 8)
            }
            .frame(width: 370, height: 440)
            .rotationEffect(.degrees(-35))
            .shadow(color: Color(red: 1, green: 0.70, blue: 0.40).opacity(0.65), radius: 70)
            .shadow(color: .black.opacity(0.45), radius: 18, y: 16)
            .offset(x: 18, y: 40)
        }
        .frame(width: 824, height: 824)
        .clipShape(RoundedRectangle(cornerRadius: 186, style: .continuous)) // the glow stays inside the tile
        .frame(width: 1024, height: 1024)
    }
}

MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    guard let image = renderer.cgImage, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        fatalError("render failed")
    }
    try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
