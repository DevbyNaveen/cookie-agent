//
//  CookieSceneView.swift
//  Cookie
//
//  Draws a 3D scene (`CookieScene`) with RealityKit's RealityView (macOS 15)
//  on Cookie's paper card: the parts lit by a soft studio light, framed from
//  the scene's own size, labelled with paper pills and hand-inked leader lines
//  drawn in SwiftUI at each part's projected point (RealityView's in-scene
//  attachments are visionOS-only). Dragging turns the model, scrolling zooms.
//  `CookieScenePresenter` floats it like a card: one at a time, beside the
//  notch or the marks, click-through except while the pointer is over it.
//
//  The scene sits on the paper whether or not RealityView draws its own
//  background: the view's background style is the paper, and the card is
//  rounded around it either way.
//

import AppKit
import RealityKit
import SwiftUI

/// The live scene: its entities, camera and lights, how far it's turned and zoomed, and where each
/// shown label's part is on the view. Built once per scene; dropped with the panel.
@MainActor
final class CookieSceneStage: ObservableObject {
    let scene: CookieScene
    let teachingOwner = UUID()
    @Published var collapsed = false
    @Published private(set) var activePart: String?
    private(set) var selectedPart: String?
    var onFocus: (CGPoint) -> Void = { _ in }
    var viewportOrigin = CGPoint.zero
    /// Turned by dragging and spinning; the parts hang from it with the scene's centroid at its origin.
    let root = Entity()
    private let camera = PerspectiveCamera()
    private var lights: [Entity] = []
    private var parts: [String: ModelEntity] = [:]

    /// How many labels are showing, in `scene.labelled` order.
    @Published private(set) var shownLabels = 0
    /// Each shown label's part, projected onto the view (view points, top-left origin).
    @Published private(set) var anchors: [String: CGPoint] = [:]
    /// The scene's centre on the view; labels lean away from it.
    @Published private(set) var middle: CGPoint?

    /// Called on a drag or scroll, so the presenter keeps the scene up while it's being looked at.
    var onInteract: () -> Void = {}

    private let reduceMotion: Bool
    private var spinning: Bool
    private var turn = simd_quatf(angle: -0.5, axis: [0, 1, 0])
    private var dragBase: simd_quatf?
    private var zoom: Float = 1
    @Published private(set) var exploded = false
    private var subscription: EventSubscription?
    private var initialExplosionStarted = false
    private var explosionTask: Task<Void, Never>?

    private static let fieldOfView: Float = 34

    init(scene: CookieScene, reduceMotion: Bool) {
        self.scene = scene
        self.reduceMotion = reduceMotion
        self.spinning = scene.spin && !reduceMotion
        let studio = Self.studioLight()
        for part in scene.parts {
            let entity = ModelEntity(mesh: Self.mesh(part), materials: [Self.material(part)])
            entity.position = scene.place(of: part, exploded: false)
            entity.orientation = part.orientation
            if let studio { entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: studio)) }
            root.addChild(entity)
            parts[part.id] = entity
        }
        root.orientation = turn
        // A key light from above and in front, a dim fill from the other side; the studio image does the rest.
        let key = DirectionalLight()
        key.light.intensity = studio == nil ? 2600 : 1400
        key.look(at: .zero, from: [1.2, 2.4, 2], relativeTo: nil)
        let fill = DirectionalLight()
        fill.light.intensity = studio == nil ? 900 : 400
        fill.look(at: .zero, from: [-2, 0.6, 1], relativeTo: nil)
        lights = [key, fill] + (studio.map { [$0] } ?? [])
        camera.camera.fieldOfViewInDegrees = Self.fieldOfView
        placeCamera()
    }

    /// Puts the scene into the RealityView and starts the per-frame update (spin and label positions).
    func install(in content: inout RealityViewCameraContent) {
        subscription?.cancel()
        content.camera = .virtual
        content.add(root)
        content.add(camera)
        lights.forEach { content.add($0) }
        let projector = content
        // RealityKit doesn't document which thread delivers the update, so a frame runs where it lands
        // when that's the main thread (in step with the render) and is handed to the main thread otherwise.
        subscription = content.subscribe(to: SceneEvents.Update.self, on: nil, componentType: nil) { [weak self] event in
            let seconds = Float(event.deltaTime)
            let step: @MainActor () -> Void = { self?.frame(seconds) { projector.project(point: $0, to: .local) } }
            if Thread.isMainThread {
                MainActor.assumeIsolated(step)
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated(step) }
            }
        }
    }

    /// Stops the per-frame work and lets go of every entity.
    func release() {
        pauseTeaching()
        subscription?.cancel()
        subscription = nil
        root.children.removeAll()
        parts = [:]
        lights = []
    }

    // MARK: Beats

    /// Beat 0 is the scene itself (an exploding scene comes apart a moment after it appears); beat n
    /// shows the first n labels. `all` shows everything at once.
    func reveal(through beat: Int, all: Bool) {
        let count = all ? scene.labelled.count : min(scene.labelled.count, beat)
        if count > shownLabels { shownLabels = count }
        if !all, count > 0 { focus(scene.labelled[count - 1].id) }
        guard scene.explode, !initialExplosionStarted else { return }
        initialExplosionStarted = true
        exploded = true
        if reduceMotion || all {
            explodeParts(animated: !reduceMotion)
            placeCamera()
        } else {
            explosionTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, let self, self.exploded else { return }
                self.explodeParts(animated: true)
                self.placeCamera()
            }
        }
    }

    /// As on cards: the hand follows the active part only while Cookie explains it.
    private var handFollows = false

    func focus(_ id: String, hand: Bool = true) {
        guard scene.labelled.contains(where: { $0.id == id }) else { return }
        collapsed = false
        handFollows = hand
        activePart = id
        selectedPart = id
        parts[id]?.isEnabled = true
        spinning = false
        if let index = scene.labelled.firstIndex(where: { $0.id == id }) { shownLabels = max(shownLabels, index + 1) }
        for part in scene.parts {
            var material = Self.material(part)
            if part.id == id { material.baseColor = .init(tint: NSColor.systemOrange) }
            parts[part.id]?.model?.materials = [material]
        }
        if hand, let anchor = anchors[id] { onFocus(anchor) }
    }

    func pauseTeaching() {
        explosionTask?.cancel()
        explosionTask = nil
        handFollows = false
        activePart = nil
        CookieHand.shared.stopTeaching(owner: teachingOwner)
        for part in scene.parts { parts[part.id]?.model?.materials = [Self.material(part)] }
    }

    private func explodeParts(animated: Bool) {
        for part in scene.parts {
            guard let entity = parts[part.id] else { continue }
            var target = entity.transform
            target.translation = scene.place(of: part, exploded: exploded)
            if animated {
                entity.move(to: target, relativeTo: root, duration: 1.2, timingFunction: .easeInOut)
            } else {
                entity.transform = target
            }
        }
    }

    func apply(_ command: CookieVisualCommand) {
        explosionTask?.cancel()
        explosionTask = nil
        initialExplosionStarted = true
        collapsed = false
        spinning = false
        switch command {
        case .explode, .assemble:
            exploded = command == .explode
            explodeParts(animated: !reduceMotion)
            placeCamera()
        case .next, .previous:
            let ids = scene.labelled.map(\.id)
            guard !ids.isEmpty else { return }
            let current = selectedPart.flatMap { ids.firstIndex(of: $0) } ?? (command == .next ? -1 : ids.count)
            focus(ids[min(ids.count - 1, max(0, current + (command == .next ? 1 : -1)))])
        case .isolate:
            guard let selectedPart else { return }
            for (id, entity) in parts { entity.isEnabled = id == selectedPart }
        case .showAll:
            parts.values.forEach { $0.isEnabled = true }
        case .zoomIn: zoom(by: 20)
        case .zoomOut: zoom(by: -20)
        case .reset:
            parts.values.forEach { $0.isEnabled = true }
            exploded = false
            explodeParts(animated: !reduceMotion)
            zoom = 1
            turn = simd_quatf(angle: -0.5, axis: [0, 1, 0])
            root.orientation = turn
            placeCamera()
            pauseTeaching()
        }
        onInteract()
    }

    // MARK: Turning and zooming

    func drag(_ translation: CGSize) {
        let base = dragBase ?? turn
        dragBase = base
        spinning = false // the person has taken over
        let yaw = Float(translation.width) * 0.01, pitch = Float(translation.height) * 0.01
        turn = simd_quatf(angle: pitch, axis: [1, 0, 0]) * simd_quatf(angle: yaw, axis: [0, 1, 0]) * base
        root.orientation = turn
        onInteract()
    }

    func endDrag() {
        dragBase = nil
    }

    /// A scroll's vertical delta; up comes closer.
    func zoom(by delta: CGFloat) {
        zoom = min(3, max(0.5, zoom * Float(exp(Double(delta) * 0.01))))
        placeCamera()
        onInteract()
    }

    /// Far enough back that the scene's bounding ball fits the view's height, a little from above.
    private func placeCamera() {
        let half = Self.fieldOfView / 2 * .pi / 180
        let radius = max(0.05, scene.parts.map { simd_length(scene.place(of: $0, exploded: exploded)) + $0.reach }.max() ?? 0.05)
        let distance = radius / sin(half) * 1.12 / zoom
        camera.look(at: .zero, from: simd_normalize(SIMD3<Float>(0, 0.32, 1)) * distance, relativeTo: nil)
    }

    private func frame(_ seconds: Float, project: (SIMD3<Float>) -> CGPoint?) {
        if spinning, dragBase == nil {
            turn = simd_quatf(angle: seconds * 0.35, axis: [0, 1, 0]) * turn
            root.orientation = turn
        }
        guard shownLabels > 0 else { return }
        var points: [String: CGPoint] = [:]
        for part in scene.labelled.prefix(shownLabels) {
            if let entity = parts[part.id], entity.isEnabled, let point = project(entity.position(relativeTo: nil)) { points[part.id] = point }
        }
        let centre = project(.zero)
        // Only publish a real move: SwiftUI redraws the labels on every change.
        if points.count != anchors.count || points.contains(where: { id, point in
            anchors[id].map { abs($0.x - point.x) + abs($0.y - point.y) > 0.25 } ?? true
        }) { anchors = points }
        if handFollows, let activePart, let point = points[activePart] { onFocus(point) }
        if let centre, middle.map({ abs($0.x - centre.x) + abs($0.y - centre.y) > 0.25 }) ?? true { middle = centre }
    }

    // MARK: Building

    private static func mesh(_ part: CookieScene.Part) -> MeshResource {
        let size = part.size
        switch part.shape {
        case .box: return .generateBox(size: SIMD3(size[0], size[1], size[2]), cornerRadius: min(size[0], size[1], size[2]) * 0.04)
        case .sphere: return .generateSphere(radius: size[0])
        case .cylinder: return .generateCylinder(height: size[1], radius: size[0])
        case .cone: return .generateCone(height: size[1], radius: size[0])
        case .capsule: return MeshResource(shape: .generateCapsule(height: size[1], radius: size[0]))
        }
    }

    private static func material(_ part: CookieScene.Part) -> PhysicallyBasedMaterial {
        let (color, roughness, metallic): (NSColor, Float, Float) = switch part.tint {
        case .amber: (NSColor(red: 0.93, green: 0.56, blue: 0.24, alpha: 1), 0.45, 0)
        case .cream: (NSColor(red: 0.96, green: 0.92, blue: 0.84, alpha: 1), 0.7, 0)
        case .graphite: (NSColor(red: 0.24, green: 0.24, blue: 0.26, alpha: 1), 0.55, 0.2)
        case .sky: (NSColor(red: 0.48, green: 0.70, blue: 0.90, alpha: 1), 0.5, 0)
        case .mint: (NSColor(red: 0.55, green: 0.84, blue: 0.70, alpha: 1), 0.5, 0)
        case .rose: (NSColor(red: 0.92, green: 0.52, blue: 0.56, alpha: 1), 0.5, 0)
        case .steel: (NSColor(red: 0.72, green: 0.74, blue: 0.78, alpha: 1), 0.3, 0.9)
        case .glass: (NSColor(red: 0.85, green: 0.93, blue: 0.97, alpha: 1), 0.05, 0)
        }
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = .init(floatLiteral: roughness)
        material.metallic = .init(floatLiteral: metallic)
        // A cut part is see-through so what's inside shows; glass always is.
        let opacity: Float = part.tint == .glass ? 0.28 : part.cut ? 0.32 : 1
        if opacity < 1 {
            material.blending = .transparent(opacity: .init(floatLiteral: opacity))
            material.faceCulling = .none
        }
        return material
    }

    /// A soft studio made in code (no bundled image): a bright sky fading to a warm horizon and a
    /// darker floor, with one big softbox overhead, as an equirectangular image-based light.
    /// Nil when RealityKit can't make it; the directional lights carry the scene then.
    private static func studioLight() -> Entity? {
        let width = 128, height = 64
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(red: 1, green: 0.99, blue: 0.96, alpha: 1), CGColor(red: 0.93, green: 0.88, blue: 0.80, alpha: 1),
                      CGColor(red: 0.42, green: 0.38, blue: 0.34, alpha: 1)] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.5, 1]) else { return nil }
        // CGContext's origin is bottom-left: the image's top row (the sky) is at y = height.
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: .zero, options: [])
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 2 - 20, y: height - 14, width: 40, height: 10))
        guard let image = context.makeImage(), let environment = try? EnvironmentResource(equirectangular: image) else { return nil }
        let light = Entity()
        light.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: 0.4))
        return light
    }
}

// MARK: - View

struct CookieSceneView: View {
    @ObservedObject var stage: CookieSceneStage
    var onClose: () -> Void
    var onCollapse: (Bool) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let sceneSize = CGSize(width: 520, height: 360)

    private var paper: Color { CookieCardView.paper(colorScheme) }
    private var inkText: Color { CookieCardView.inkText(colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(stage.scene.title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(inkText)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .shadow(color: paper, radius: 2)
                .padding(.trailing, 26)
                .padding(.bottom, 5)
                .overlay(alignment: .bottomLeading) {
                    CookieCardInk(figures: [.line(CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5))], seed: 7, pen: 2.2, progress: 1)
                        .fill(CookieMarksLayer.ink)
                        .frame(width: 56, height: 4)
                }
            if !stage.collapsed {
            RealityView { content in
                stage.install(in: &content)
            }
            .backgroundStyle(Color.clear)
            .frame(width: Self.sceneSize.width, height: Self.sceneSize.height)
            .background(GeometryReader { proxy in
                Color.clear.onAppear { stage.viewportOrigin = proxy.frame(in: .named("sceneSurface")).origin }
                    .onChange(of: proxy.frame(in: .named("sceneSurface"))) { _, frame in stage.viewportOrigin = frame.origin }
            })
            .overlay { CookieSceneLabels(stage: stage, size: Self.sceneSize, paper: paper, inkText: inkText, reduceMotion: reduceMotion) }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { stage.drag($0.translation) }
                .onEnded { _ in stage.endDrag() })
            .accessibilityHidden(true)
            }
            if !stage.collapsed {
                HStack(spacing: 16) {
                    Button(stage.exploded ? "Assemble" : "Explode") { stage.apply(stage.exploded ? .assemble : .explode) }
                    Button("Previous") { stage.apply(.previous) }
                    Button("Next part") { stage.apply(.next) }
                    Button("Reset") { stage.apply(.reset) }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(inkText).shadow(color: paper, radius: 2)
                .buttonStyle(.plain).pointerCursor()
            }
            Button {
                stage.collapsed.toggle()
                stage.pauseTeaching()
            } label: {
                Label(stage.collapsed ? "Expand model" : "Collapse", systemImage: stage.collapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .foregroundStyle(inkText).background(Capsule().fill(paper))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(inkText.opacity(0.58))
                    .frame(width: CookieCardView.closeSize, height: CookieCardView.closeSize)
                    .background(Circle().fill(paper))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Close model")
            .padding(CookieCardView.closeInset)
        }
        .padding(CookieCardView.shadowMargin)
        .coordinateSpace(name: "sceneSurface")
        .onChange(of: stage.collapsed) { _, value in onCollapse(value) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(stage.scene.spokenSummary)
    }
}

/// Borderless labels stay in stable lanes while quiet leaders follow the geometry.
private struct CookieSceneLabels: View {
    @ObservedObject var stage: CookieSceneStage
    let size: CGSize
    let paper: Color
    let inkText: Color
    let reduceMotion: Bool

    var body: some View {
        let available = Array(stage.scene.labelled.prefix(stage.shownLabels))
        let recent = Array(available.filter { $0.id != stage.activePart }.suffix(stage.activePart == nil ? 6 : 5))
        let visible = available.count <= 6 ? available : available.filter { part in recent.contains(where: { $0.id == part.id }) || part.id == stage.activePart }
        let shown = Array(visible.enumerated())
        ZStack(alignment: .topLeading) {
            ForEach(shown, id: \.element.id) { index, part in
                if let anchor = stage.anchors[part.id], let label = part.label {
                    let pill = CookieSceneLabelLayout.centre(index: index, count: shown.count, size: size)
                    CookieCardInk(figures: [.line(unit(anchor), unit(pill))], seed: UInt32(index + 11), pen: 0.8, progress: 1)
                        .fill(CookieMarksLayer.ink.opacity(stage.activePart == part.id ? 0.85 : 0.35))
                        .frame(width: size.width, height: size.height)
                        .allowsHitTesting(false)
                    Circle()
                        .fill(CookieMarksLayer.ink)
                        .frame(width: 4, height: 4)
                        .position(anchor)
                    Text(label)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(stage.activePart == part.id ? CookieMarksLayer.ink : inkText)
                        .fontWeight(stage.activePart == part.id ? .bold : .medium)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 130)
                        .padding(4)
                        .shadow(color: paper, radius: 2)
                        .shadow(color: paper, radius: 1)
                        .contentShape(Rectangle())
                        .pointerCursor()
                        .position(pill)
                        .onTapGesture { stage.focus(part.id, hand: false) }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("Focus on \(label)")
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: stage.shownLabels)
    }

    private func unit(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / size.width, y: point.y / size.height)
    }
}

/// Stable rails keep labels apart while their leader lines follow the rotating geometry.
enum CookieSceneLabelLayout {
    static func centre(index: Int, count: Int, size: CGSize) -> CGPoint {
        let row = index / 2
        let rows = max(1, (min(6, count) + 1) / 2)
        return CGPoint(x: index % 2 == 0 ? 78 : size.width - 78,
                       y: 74 + CGFloat(row) * (size.height - 148) / CGFloat(max(1, rows - 1)))
    }
}

// MARK: - Presenter

/// Floats one scene at a time, placed like a card (beside the marks, else beside the notch). It
/// never takes focus and lets clicks through until the pointer is over it; then dragging turns the
/// model and scrolling zooms. Escape, a click elsewhere, the next question, or 45 s with nothing
/// new and nobody turning it dismisses it, and the RealityView goes with the panel.
@MainActor
final class CookieScenePresenter {
    private var panel: NSPanel?
    var previewWindowNumber: Int? { panel?.windowNumber }
    var previewFrame: CGRect? { panel?.frame }
    private var stage: CookieSceneStage?
    private var schedules: [CookieSpeechClock.Scheduled] = []
    private weak var clock: CookieSpeechClock?
    private var monitors: [Any] = []
    private var fadeTimer: Task<Void, Never>?
    private var lastActive = Date()

    var teachingContext: String? {
        guard let stage else { return nil }
        return "Visible 3D model: \(stage.scene.title). Selected: \(stage.selectedPart ?? "none"). Exploded: \(stage.exploded). Parts: " + stage.scene.labelled.map { "\($0.id)=\($0.label ?? $0.id)" }.joined(separator: "; ")
    }
    func pauseTeaching() { cancelSchedules(); stage?.pauseTeaching() }
    @discardableResult func apply(_ command: CookieVisualCommand) -> Bool {
        guard let stage else { return false }
        stage.apply(command)
        return true
    }
    @discardableResult func focus(_ id: String) -> Bool {
        guard let stage, stage.scene.labelled.contains(where: { $0.id == id }) else { return false }
        stage.focus(id)
        restartFadeTimer()
        return true
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func prepare(_ scene: CookieScene, clock: CookieSpeechClock) {
        cancelSchedules()
        self.clock = clock
        schedules.append(clock.schedule(atOffset: scene.offset) { [weak self] in
            _ = self?.show(scene, near: nil)
        })
    }

    /// Puts the scene on the speech clock: it appears at its tag and its labels follow the sentence
    /// after it. Call from `onPlaybackStarted`.
    func schedule(_ scene: CookieScene, spoken: String, near region: (rect: CGRect, display: CGRect)?, clock: CookieSpeechClock) {
        cancelSchedules()
        self.clock = clock
        let offsets = scene.revealOffsets(in: spoken)
        var shown: CookieSceneStage?
        for (beat, offset) in offsets.enumerated() {
            schedules.append(clock.schedule(atOffset: offset) { [weak self] in
                guard let self else { return }
                if beat == 0 { shown = self.show(scene, near: region) }
                guard let shown, shown === self.stage else { return }
                shown.reveal(through: beat, all: self.reduceMotion)
                self.restartFadeTimer()
            })
        }
    }

    /// A scene that isn't spoken (a typed answer): all of it now.
    func showNow(_ scene: CookieScene, near region: (rect: CGRect, display: CGRect)?) {
        cancelSchedules()
        show(scene, near: region).reveal(through: scene.labelled.count, all: true)
        restartFadeTimer()
    }

    func dismiss() {
        stage?.pauseTeaching()
        cancelSchedules()
        fadeTimer?.cancel()
        fadeTimer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let panel { fadeOut(panel, stage: stage) }
        panel = nil
        stage = nil
    }

    // MARK: Showing

    private func cancelSchedules() {
        if let clock { schedules.forEach(clock.cancel) }
        schedules = []
    }

    @discardableResult
    private func show(_ scene: CookieScene, near region: (rect: CGRect, display: CGRect)?) -> CookieSceneStage {
        if let stage, stage.scene == scene { return stage }
        let newStage = CookieSceneStage(scene: scene, reduceMotion: reduceMotion)
        newStage.onInteract = { [weak self] in self?.restartFadeTimer() }
        let hosting = CookieSceneHostingView(rootView: CookieSceneView(stage: newStage, onClose: { [weak self] in self?.dismiss() }))
        let newPanel = CookieCardPanel(contentRect: CookieCardPresenter.frame(for: hosting.fittingSize, near: region))
        newPanel.contentView = hosting
        newPanel.isMovableByWindowBackground = true
        let expandedSize = newPanel.frame.size
        hosting.rootView.onCollapse = { [weak newPanel] collapsed in
            guard let panel = newPanel else { return }
            let height = collapsed ? 160.0 : expandedSize.height
            panel.setFrame(CGRect(x: panel.frame.minX, y: panel.frame.maxY - height, width: expandedSize.width, height: height), display: true)
        }
        newPanel.alphaValue = 0
        newPanel.orderFrontRegardless()
        // Use the renderer's projection, not OCR or model-generated screen coordinates.
        newStage.onFocus = { [weak newPanel, weak hosting, weak newStage] local in
            guard let panel = newPanel, let hosting, let stage = newStage else { return }
            // GeometryReader reports the RealityView's origin in the hosting view.
            let origin = stage.viewportOrigin
            let point = CGPoint(x: panel.frame.minX + origin.x + local.x,
                                y: panel.frame.maxY - origin.y - local.y)
            if hosting.bounds.contains(CGPoint(x: origin.x + local.x, y: origin.y + local.y)) {
                CookieHand.shared.teach(owner: stage.teachingOwner, at: point)
            }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            newPanel.animator().alphaValue = 1
        }
        stage?.pauseTeaching()
        if let old = panel { fadeOut(old, stage: stage) }
        panel = newPanel
        stage = newStage
        installMonitors()
        restartFadeTimer()
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: scene.spokenSummary, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        return newStage
    }

    /// Fades the panel, then drops its RealityView and the scene's entities.
    private func fadeOut(_ panel: NSPanel, stage: CookieSceneStage?) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.contentView = nil
                panel.close()
                stage?.release()
            }
        })
    }

    /// The same idle rule as cards (`CookieLessonIdle`): folded, the RealityView goes away and stops drawing.
    private func restartFadeTimer() {
        lastActive = Date()
        guard fadeTimer == nil else { return }
        fadeTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, let stage = self.stage else { return }
                switch CookieLessonIdle.step(idle: Date().timeIntervalSince(self.lastActive), collapsed: stage.collapsed) {
                case .close: self.dismiss(); return
                case .collapse: stage.pauseTeaching(); stage.collapsed = true
                case .stay: break
                }
            }
        }
    }

    // MARK: Pointer and keys

    /// The card itself in screen coordinates (inside the shadow margin): over it, the scene takes the pointer.
    private var cardRect: CGRect {
        panel?.frame.insetBy(dx: CookieCardView.shadowMargin, dy: CookieCardView.shadowMargin) ?? .null
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let follow: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                let over = self.cardRect.contains(NSEvent.mouseLocation)
                panel.ignoresMouseEvents = !over
                if over { self.lastActive = Date() }
            }
        }
        if let moved = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: follow) { monitors.append(moved) }
        if let moved = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { follow($0); return $0 }) { monitors.append(moved) }
        if let scrolls = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 8)
            let window = event.window
            let zoomed = MainActor.assumeIsolated { () -> Bool in
                guard let self, window === self.panel, let stage = self.stage else { return false }
                stage.zoom(by: delta)
                return true
            }
            return zoomed ? nil : event
        }) { monitors.append(scrolls) }
        // As with cards: Escape elsewhere belongs to that app unless the pointer is over the model.
        let escape: (NSEvent, Bool) -> Void = { [weak self] event, local in
            MainActor.assumeIsolated {
                guard event.keyCode == 53, let self else { return }
                if local || self.cardRect.contains(NSEvent.mouseLocation) { self.dismiss() }
            }
        }
        if let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { escape($0, false) }) { monitors.append(keys) }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { escape($0, true); return $0 }) { monitors.append(keys) }
    }
}

/// The scene answers the first click and drag even though Cookie isn't the active app.
private final class CookieSceneHostingView: NSHostingView<CookieSceneView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
