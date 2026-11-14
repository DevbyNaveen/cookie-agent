import MetalKit
import SwiftUI

/// Enkeon's orb: a glass sphere of slow, domain-warped fluid — teal, violet and amber swirling over
/// deep ink — lit from the upper left. The same shader idea as Cookie's orb, in Enkeon's colors.
/// `energy` (the microphone level while listening, 0…1) speeds the fluid up and stirs it harder;
/// the change eases in, never snaps. Without Metal it is a still gradient sphere.
struct FluidOrb: View {
    var energy: CGFloat
    var palette: OrbPalette = .brand
    var framesPerSecond: Int = 60
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if FluidOrbRenderer.pipeline != nil && !reduceMotion {
            MetalOrb(energy: Float(energy), palette: palette, framesPerSecond: framesPerSecond)
        } else {
            Circle().fill(RadialGradient(colors: palette.colors.map { Color(red: Double($0.x), green: Double($0.y), blue: Double($0.z)) },
                                         center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 90))
        }
    }
}

/// The orb's colors for each stage: the light at the top, two currents, and the warm accent.
/// Changing palette blends over about half a second, never a cut.
enum OrbPalette: Equatable {
    case brand, listening, memory, thinking, success, warning

    var colors: [SIMD4<Float>] {
        switch self {
        case .brand: return [rgb(0.66, 0.88, 0.96), rgb(0.17, 0.50, 0.64), rgb(0.50, 0.38, 0.86), rgb(0.93, 0.60, 0.30)]
        case .listening: return [rgb(0.70, 0.92, 0.98), rgb(0.15, 0.52, 0.68), rgb(0.26, 0.74, 0.86), rgb(0.48, 0.42, 0.90)]
        case .memory: return [rgb(1.00, 0.92, 0.78), rgb(0.93, 0.58, 0.26), rgb(0.82, 0.38, 0.20), rgb(0.88, 0.45, 0.55)]
        case .thinking: return [rgb(0.86, 0.84, 1.00), rgb(0.46, 0.36, 0.86), rgb(0.28, 0.30, 0.72), rgb(0.30, 0.66, 0.82)]
        case .success: return [rgb(0.80, 1.00, 0.90), rgb(0.22, 0.72, 0.52), rgb(0.18, 0.58, 0.62), rgb(0.55, 0.85, 0.95)]
        case .warning: return [rgb(1.00, 0.88, 0.74), rgb(0.90, 0.55, 0.22), rgb(0.80, 0.32, 0.26), rgb(0.95, 0.70, 0.35)]
        }
    }

    private func rgb(_ r: Float, _ g: Float, _ b: Float) -> SIMD4<Float> { SIMD4(r, g, b, 1) }
}

private struct MetalOrb: NSViewRepresentable {
    let energy: Float
    let palette: OrbPalette
    let framesPerSecond: Int

    func makeCoordinator() -> FluidOrbRenderer { FluidOrbRenderer(palette: palette) }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: FluidOrbRenderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.preferredFramesPerSecond = framesPerSecond
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        view.preferredFramesPerSecond = framesPerSecond
        context.coordinator.target = energy
        context.coordinator.targetColors = palette.colors
    }
    static func dismantleNSView(_ view: MTKView, coordinator: FluidOrbRenderer) {
        view.isPaused = true
        view.delegate = nil
    }
}

final class FluidOrbRenderer: NSObject, MTKViewDelegate {
    static let device = MTLCreateSystemDefaultDevice()
    static let pipeline: MTLRenderPipelineState? = {
        guard let device, let library = try? device.makeLibrary(source: shader, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "orb_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "orb_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }()

    private struct Uniforms {
        var time: Float; var energy: Float; var resolution: SIMD2<Float>
        var light: SIMD4<Float>; var currentA: SIMD4<Float>; var currentB: SIMD4<Float>; var accent: SIMD4<Float>
    }

    private let queue = FluidOrbRenderer.device?.makeCommandQueue()
    var target: Float = 0
    var targetColors: [SIMD4<Float>]
    private var colors: [SIMD4<Float>]

    init(palette: OrbPalette) {
        colors = palette.colors
        targetColors = palette.colors
    }
    private var energy: Float = 0
    private var phase = Float.random(in: 0..<100)
    private var last = CACurrentMediaTime()

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, now - last))
        last = now
        energy += (min(1, target * 1.8) - energy) * min(1, dt * 5)
        phase += dt * (0.32 + 1.4 * energy)
        let blend = min(1, dt * 4)
        for index in colors.indices { colors[index] += (targetColors[index] - colors[index]) * blend }
        guard let pipeline = Self.pipeline, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue?.makeCommandBuffer(), let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = Uniforms(time: phase, energy: energy,
                                resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
                                light: colors[0], currentA: colors[1], currentB: colors[2], accent: colors[3])
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct Varying { float4 position [[position]]; float2 uv; };
    struct Uniforms { float time; float energy; float2 resolution; float4 light; float4 currentA; float4 currentB; float4 accent; };

    vertex Varying orb_vertex(uint id [[vertex_id]]) {
        float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        Varying out;
        out.position = float4(corners[id], 0, 1);
        out.uv = corners[id];
        return out;
    }

    float hash(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }
    float noise(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash(i), hash(i + float2(1, 0)), u.x), mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), u.x), u.y);
    }
    float fbm(float2 p) {
        const float2x2 R = float2x2(0.8, 0.6, -0.6, 0.8);
        float v = 0.0, a = 0.5;
        for (int i = 0; i < 5; i++) { v += a * noise(p); p = R * p * 2.03; a *= 0.5; }
        return v;
    }

    fragment float4 orb_fragment(Varying in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = in.uv;
        float r = length(uv);
        float z = sqrt(max(0.0, 1.0 - r * r));
        float3 n = normalize(float3(uv, z));

        // Fluid on the sphere: coordinates stretch toward the rim, so it curves with the glass.
        float2 p = uv / (0.45 + 0.55 * z) * 1.25;
        float t = u.time;
        float stir = 3.0 + 1.5 * u.energy;
        float2 q = float2(fbm(p + float2(0.0, t * 0.9)), fbm(p + float2(5.2, 1.3) - t * 0.7));
        float2 w = float2(fbm(p + stir * q + float2(1.7, 9.2) + t * 0.5), fbm(p + stir * q + float2(8.3, 2.8) - t * 0.4));
        float f = fbm(p + 2.4 * w);

        // Mixed color inside: one current drifting into a second and a warm accent where they fold.
        float3 ink = float3(0.05, 0.13, 0.18);
        float3 teal = u.currentA.rgb;
        float3 sky = u.light.rgb;
        float3 violet = u.currentB.rgb;
        float3 amber = u.accent.rgb;
        float3 body = mix(teal, violet, smoothstep(0.38, 0.72, w.x));
        body = mix(body, amber, smoothstep(0.52, 0.82, w.y));
        float h = clamp(0.5 - uv.y * 0.38 + (f - 0.5) * (0.9 + 0.4 * u.energy), 0.0, 1.0);
        float3 col = mix(sky, body, smoothstep(0.12, 0.48, h));
        col = mix(col, ink, smoothstep(0.66, 1.0, h));

        // Light from the upper left, warm light caught in the lower rim, the glass edge, one bright point.
        float3 L = normalize(float3(-0.45, 0.62, 0.64));
        col *= 0.78 + 0.32 * clamp(dot(n, L), 0.0, 1.0);
        col += amber * 0.28 * pow(1.0 - z, 1.6) * smoothstep(0.3, -0.9, uv.y);
        col += float3(0.85, 0.95, 1.0) * pow(1.0 - z, 3.0) * 0.34;
        float3 H = normalize(L + float3(0, 0, 1));
        col += pow(clamp(dot(n, H), 0.0, 1.0), 70.0) * 0.6;

        float px = 2.0 / u.resolution.y;
        float a = 1.0 - smoothstep(1.0 - 1.5 * px, 1.0, r);
        return float4(min(col, 1.0) * a, a);
    }
    """
}
