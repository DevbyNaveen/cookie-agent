//
//  CookieOrb.swift
//  Cookie
//
//  Cookie's face: a living amber orb with two eyes, the same one Cookie's
//  page draws (web/components/central/CookieOrb.tsx).
//
//  The orb is our own shader, a sphere of slow, domain-warped fluid lit from
//  the upper left: diffuse light, a warm glow inside the lower rim, a fresnel
//  edge and one specular point, so it reads as glass with something alive in
//  it. Thinking speeds the fluid up; the change eases in, never snaps. The
//  shader is compiled once at runtime and shared by every orb on screen.
//
//  The eyes are SwiftUI over the orb, so they stay crisp at any size. They
//  blink on an irregular clock (sometimes twice), drift upward while thinking
//  and follow the pointer when told where it is.
//
//  A still orb (lists, the menu bar, Reduce Motion, no Metal) is the same
//  sphere as gradients with the same eyes. Only the orbs that matter move:
//  each live one is a Metal view drawing every frame.
//

import MetalKit
import SwiftUI

struct CookieOrb: View {
    enum Mood { case idle, listening, thinking, speaking, happy, sad, sleeping }

    var size: CGFloat = 32
    var mood: Mood = .idle
    /// The fluid moves (from `liveMinimum` up, as on the page).
    var live = true
    /// Where the eyes look, -1 (left) to 1 (right). Wins over `follow`.
    var gaze: CGFloat? = nil
    /// Follow the pointer when nothing else is being looked at.
    var follow = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shut = false
    @State private var wander = CGPoint.zero
    @State private var pointer = CGPoint.zero

    /// Below this a moving fluid is a smudge; the still orb reads better.
    static let liveMinimum: CGFloat = 24

    private var moving: Bool { live && !reduceMotion && size >= Self.liveMinimum && OrbRenderer.pipeline != nil }

    var body: some View {
        TimelineView(.animation(paused: !(mood == .thinking && moving))) { timeline in
            // Thinking: the orb breathes, 0.955 to 1 over 2.4 s.
            let breath = mood == .thinking && moving
                ? 0.9775 + 0.0225 * cos(timeline.date.timeIntervalSinceReferenceDate * 2 * .pi / 2.4) : 1
            ZStack {
                if moving {
                    OrbFluid(energy: Self.energy(for: mood)).clipShape(Circle())
                } else {
                    Circle().fill(Self.stillSphere(size: size))
                }
                glass
                eyes
            }
            .frame(width: size, height: size)
            .scaleEffect(breath)
        }
        .frame(width: size, height: size)
        .background {
            if follow && gaze == nil && mood != .thinking && !reduceMotion {
                PointerProbe { pointer = $0 }
            }
        }
        .shadow(color: Color(red: 214 / 255, green: 118 / 255, blue: 43 / 255).opacity(0.55),
                radius: size * 0.09, y: size * 0.06)
        .task(id: mood == .sleeping) { await blink() }
        .task(id: mood == .thinking && !reduceMotion) { await wanderWhileThinking() }
        .accessibilityHidden(true)
    }

    // MARK: Glass

    /// A fine bright rim, a soft highlight and a little shade inside the bottom edge, over both forms.
    private var glass: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [.white.opacity(0.34), .white.opacity(0)],
                                         center: UnitPoint(x: 0.33, y: 0.22), startRadius: 0, endRadius: size * 0.35))
            Circle().strokeBorder(.white.opacity(0.42), lineWidth: 0.5)
            Circle()
                .stroke(Color(red: 110 / 255, green: 50 / 255, blue: 6 / 255).opacity(0.3), lineWidth: size * 0.08)
                .blur(radius: size * 0.05)
                .offset(y: size * 0.04)
                .clipShape(Circle())
        }
        .allowsHitTesting(false)
    }

    static func stillSphere(size: CGFloat) -> RadialGradient {
        RadialGradient(stops: [
            .init(color: Color(red: 1, green: 250 / 255, blue: 242 / 255), location: 0),
            .init(color: Color(red: 1, green: 226 / 255, blue: 189 / 255), location: 0.2),
            .init(color: Color(red: 240 / 255, green: 163 / 255, blue: 92 / 255), location: 0.52),
            .init(color: Color(red: 201 / 255, green: 99 / 255, blue: 31 / 255), location: 0.8),
            .init(color: Color(red: 158 / 255, green: 70 / 255, blue: 18 / 255), location: 1),
        ], center: UnitPoint(x: 0.36, y: 0.26), startRadius: 0, endRadius: size * 0.98)
    }

    // MARK: Eyes

    private var eyes: some View {
        let width = max(1.6, size * 0.095)
        let height = max(3, size * 0.235)
        let look: CGPoint = mood == .thinking ? wander
            : mood == .listening ? .zero
            : gaze.map { CGPoint(x: max(-1, min(1, $0)), y: 0) } ?? (follow ? pointer : .zero)
        let closed = shut || mood == .sleeping
        let open: CGFloat = closed ? 0.1 : mood == .happy ? 0.45 : mood == .thinking ? 0.86 : mood == .listening ? 1.1 : 1
        let droop: CGFloat = mood == .sad ? size * 0.03 : 0
        return HStack(spacing: size * 0.15) {
            ForEach(0..<2, id: \.self) { _ in
                Capsule()
                    .fill(Color(red: 42 / 255, green: 20 / 255, blue: 6 / 255))
                    .frame(width: width, height: height)
                    .shadow(color: .white.opacity(0.25), radius: 0, y: 0.5)
                    .scaleEffect(x: 1, y: open, anchor: UnitPoint(x: 0.5, y: 0.55))
                    .animation(.easeInOut(duration: 0.09), value: open)
            }
        }
        .offset(x: look.x * size * 0.1, y: look.y * size * 0.08 - size * 0.035 + droop)
        .animation(reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.45), value: look)
    }

    /// Every 2.4 to 6 s, shut for 110 ms; now and then twice, 160 ms apart.
    private func blink() async {
        guard mood != .sleeping else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(Int.random(in: 2400...6000)))
            for time in 0..<(Double.random(in: 0..<1) < 0.22 ? 2 : 1) {
                if time > 0 { try? await Task.sleep(for: .milliseconds(160)) }
                guard !Task.isCancelled else { return }
                shut = true
                try? await Task.sleep(for: .milliseconds(110))
                shut = false
            }
        }
    }

    /// Thinking: the eyes drift between a few points up and to the side, as if working something out.
    private func wanderWhileThinking() async {
        guard mood == .thinking, !reduceMotion else {
            wander = .zero
            return
        }
        let spots = [CGPoint(x: 0.55, y: -0.7), CGPoint(x: -0.35, y: -0.75), CGPoint(x: 0.15, y: -0.9), CGPoint(x: 0.7, y: -0.35)]
        var index = 0
        while !Task.isCancelled {
            wander = spots[index]
            index = (index + 1) % spots.count
            try? await Task.sleep(for: .milliseconds(1400))
        }
    }

    /// How fast the fluid moves: 0 at rest, 1 while thinking.
    static func energy(for mood: Mood) -> Float {
        switch mood {
        case .thinking: return 1
        case .speaking: return 0.55
        case .listening: return 0.35
        case .idle, .happy, .sad, .sleeping: return 0
        }
    }
}

// MARK: - Following the pointer

/// Where the pointer is, relative to the orb, as a vector of length at most 1 (y down),
/// reaching full length 360 pt away. Read 30 times a second; moving the mouse needs no permission.
private struct PointerProbe: NSViewRepresentable {
    let report: (CGPoint) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.report = report
        context.coordinator.start()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { context.coordinator.report = report }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.timer?.invalidate() }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: NSView?
        var report: (CGPoint) -> Void = { _ in }
        var timer: Timer?
        private var last: CGPoint?

        func start() {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        }

        private func tick() {
            guard let view, let window = view.window, window.occlusionState.contains(.visible) else { return }
            let centre = window.convertPoint(toScreen: view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - centre.x, dy = centre.y - mouse.y
            let distance = hypot(dx, dy)
            let k = min(1, distance / 360) / max(distance, 1)
            let look = CGPoint(x: (dx * k * 100).rounded() / 100, y: (dy * k * 100).rounded() / 100)
            guard look != last else { return }
            last = look
            report(look)
        }
    }
}

// MARK: - The fluid

private struct OrbFluid: NSViewRepresentable {
    var energy: Float

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: OrbRenderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        context.coordinator.target = energy
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.target = energy
    }

    func makeCoordinator() -> OrbRenderer { OrbRenderer() }
}

/// Draws one orb. The device, shader and pipeline are shared by every orb.
final class OrbRenderer: NSObject, MTKViewDelegate {
    static let device = MTLCreateSystemDefaultDevice()
    static let queue = device?.makeCommandQueue()
    /// Nil when Metal or the shader is unavailable: every orb is then still.
    static let pipeline: MTLRenderPipelineState? = {
        guard let device, let library = try? device.makeLibrary(source: shader, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "orb_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "orb_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }()

    var target: Float = 0
    private var energy: Float = 0
    // Starts a little way in, so the first frame is already a settled swirl.
    private var clock: Float = 3.7
    private var last = CACurrentMediaTime()

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // A window nobody can see draws nothing.
        guard view.window?.occlusionState.contains(.visible) == true else { return }
        let now = CACurrentMediaTime()
        let dt = Float(min(0.05, now - last))
        last = now
        // The fluid's clock runs faster while thinking; energy eases toward its target.
        energy += (target - energy) * min(1, dt * 2.5)
        clock += dt * (0.1 + 0.32 * energy)

        guard let pipeline = Self.pipeline, let queue = Self.queue,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = (Float(view.drawableSize.width), Float(view.drawableSize.height), clock, energy)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout.size(ofValue: uniforms), index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    /// The page's fragment shader in Metal. Metal's pixel y runs down, so uv.y is flipped to match.
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { float2 res; float time; float energy; };

    vertex float4 orb_vertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        return float4(p * 2.0 - 1.0, 0.0, 1.0);
    }

    static float hash(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }
    static float noise(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash(i), hash(i + float2(1.0, 0.0)), u.x),
                   mix(hash(i + float2(0.0, 1.0)), hash(i + float2(1.0, 1.0)), u.x), u.y);
    }
    static float fbm(float2 p) {
        const float2x2 R = float2x2(0.8, 0.6, -0.6, 0.8);
        float v = 0.0, a = 0.5;
        for (int i = 0; i < 5; i++) { v += a * noise(p); p = R * p * 2.03; a *= 0.5; }
        return v;
    }

    fragment float4 orb_fragment(float4 position [[position]], constant Uniforms& u [[buffer(0)]]) {
        const float3 deep = float3(0.74, 0.33, 0.08);
        const float3 mid = float3(0.93, 0.56, 0.24);
        const float3 light = float3(1.0, 0.96, 0.9);

        float2 uv = (position.xy * 2.0 - u.res) / u.res.y;
        uv.y = -uv.y;
        float r = length(uv);
        float z = sqrt(max(0.0, 1.0 - r * r));
        float3 n = normalize(float3(uv, z));

        // Fluid on the sphere: coordinates stretch toward the rim, so it curves.
        float2 p = uv / (0.45 + 0.55 * z) * 1.25;
        float t = u.time;
        float2 q = float2(fbm(p + float2(0.0, t * 0.9)), fbm(p + float2(5.2, 1.3) - t * 0.7));
        float2 w = float2(fbm(p + 3.0 * q + float2(1.7, 9.2) + t * 0.5), fbm(p + 3.0 * q + float2(8.3, 2.8) - t * 0.4));
        float f = fbm(p + 2.4 * w);

        // Light at the top, deep amber settling at the bottom, the fluid between.
        float h = clamp(0.48 - uv.y * 0.42 + (f - 0.5) * (0.85 + 0.25 * u.energy), 0.0, 1.0);
        float3 col = mix(light, mid, smoothstep(0.18, 0.55, h));
        col = mix(col, deep, smoothstep(0.55, 0.98, h));

        float3 L = normalize(float3(-0.45, 0.62, 0.64));
        col *= 0.8 + 0.3 * clamp(dot(n, L), 0.0, 1.0);
        // Warm light caught inside the lower rim.
        col += mid * 0.35 * pow(1.0 - z, 1.6) * smoothstep(0.3, -0.9, uv.y);
        // The glass edge and the one bright point.
        col += float3(1.0, 0.93, 0.84) * pow(1.0 - z, 3.0) * 0.32;
        float3 H = normalize(L + float3(0.0, 0.0, 1.0));
        col += pow(clamp(dot(n, H), 0.0, 1.0), 70.0) * 0.6;

        float px = 2.0 / u.res.y;
        float a = 1.0 - smoothstep(1.0 - 1.5 * px, 1.0, r);
        return float4(min(col, 1.0) * a, a);
    }
    """
}
