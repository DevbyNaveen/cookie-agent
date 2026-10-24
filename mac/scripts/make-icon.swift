// Draws Cookie's app icon: Cookie's orb under the notch, on a graphite tile. The orb's fluid is
// rendered by the app's own shader (read from Cookie/CookieOrb.swift), so the icon is the face the app shows.
// Run: swift scripts/make-icon.swift <out.png>   (1024×1024; scripts/make-icon.sh builds the .icns)
import AppKit
import Metal
import SwiftUI

let orbSize = 520

/// One frame of the orb's fluid at rest, as the app draws its first frame.
func renderFluid(pixels: Int) -> CGImage {
    let source = try! String(contentsOfFile: "Cookie/CookieOrb.swift", encoding: .utf8)
    guard let open = source.range(of: "private static let shader = \"\"\"\n"),
          let close = source.range(of: "\n    \"\"\"", range: open.upperBound..<source.endIndex) else { fatalError("shader not found in CookieOrb.swift") }
    let shader = source[open.upperBound..<close.lowerBound].split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.hasPrefix("    ") ? String($0.dropFirst(4)) : String($0) }.joined(separator: "\n")

    let device = MTLCreateSystemDefaultDevice()!
    let library = try! device.makeLibrary(source: shader, options: nil)
    let pipeline = MTLRenderPipelineDescriptor()
    pipeline.vertexFunction = library.makeFunction(name: "orb_vertex")
    pipeline.fragmentFunction = library.makeFunction(name: "orb_fragment")
    pipeline.colorAttachments[0].pixelFormat = .rgba8Unorm
    let state = try! device.makeRenderPipelineState(descriptor: pipeline)

    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: pixels, height: pixels, mipmapped: false)
    textureDescriptor.usage = [.renderTarget, .shaderRead]
    textureDescriptor.storageMode = .shared
    let texture = device.makeTexture(descriptor: textureDescriptor)!
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    pass.colorAttachments[0].storeAction = .store

    let commands = device.makeCommandQueue()!.makeCommandBuffer()!
    let encoder = commands.makeRenderCommandEncoder(descriptor: pass)!
    var uniforms = (Float(pixels), Float(pixels), Float(3.7), Float(0))
    encoder.setRenderPipelineState(state)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout.size(ofValue: uniforms), index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
    commands.commit()
    commands.waitUntilCompleted()

    var bytes = [UInt8](repeating: 0, count: pixels * pixels * 4)
    texture.getBytes(&bytes, bytesPerRow: pixels * 4, from: MTLRegionMake2D(0, 0, pixels, pixels), mipmapLevel: 0)
    let context = CGContext(data: &bytes, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return context.makeImage()!
}

struct Icon: View {
    let fluid: CGImage

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: 186, style: .continuous)
        let size = CGFloat(orbSize)
        ZStack {
            // Graphite tile, lit from the top, with the orb's warmth below the notch.
            tile.fill(LinearGradient(colors: [Color(white: 0.20), Color(white: 0.09)], startPoint: .top, endPoint: .bottom))
            tile.fill(RadialGradient(colors: [Color(red: 0.93, green: 0.56, blue: 0.24).opacity(0.28), .clear],
                                     center: UnitPoint(x: 0.5, y: 0.56), startRadius: 0, endRadius: 430))
            tile.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.03)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 3)
            // The notch Cookie lives in.
            UnevenRoundedRectangle(cornerRadii: .init(bottomLeading: 44, bottomTrailing: 44), style: .continuous)
                .fill(Color.black)
                .frame(width: 330, height: 78)
                .frame(maxHeight: .infinity, alignment: .top)
            // Cookie: the fluid, the glass over it, the eyes (CookieOrb's proportions).
            ZStack {
                Image(decorative: fluid, scale: 1).resizable()
                Circle().fill(RadialGradient(colors: [.white.opacity(0.34), .white.opacity(0)],
                                             center: UnitPoint(x: 0.33, y: 0.22), startRadius: 0, endRadius: size * 0.35))
                Circle().strokeBorder(.white.opacity(0.42), lineWidth: 3)
                Circle().stroke(Color(red: 110 / 255, green: 50 / 255, blue: 6 / 255).opacity(0.3), lineWidth: size * 0.08)
                    .blur(radius: size * 0.05).offset(y: size * 0.04).clipShape(Circle())
                HStack(spacing: size * 0.15) {
                    ForEach(0..<2, id: \.self) { _ in
                        Capsule().fill(Color(red: 42 / 255, green: 20 / 255, blue: 6 / 255))
                            .frame(width: size * 0.095, height: size * 0.235)
                    }
                }
                .offset(y: -size * 0.035)
            }
            .frame(width: size, height: size)
            .shadow(color: Color(red: 214 / 255, green: 118 / 255, blue: 43 / 255).opacity(0.55), radius: size * 0.09, y: size * 0.06)
            .offset(y: 40)
        }
        .frame(width: 824, height: 824)
        .clipShape(RoundedRectangle(cornerRadius: 186, style: .continuous)) // the glow stays inside the tile
        .frame(width: 1024, height: 1024)
    }
}

MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Icon(fluid: renderFluid(pixels: orbSize)))
    renderer.scale = 1
    guard let image = renderer.cgImage, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        fatalError("render failed")
    }
    try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
