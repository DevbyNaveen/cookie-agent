//
//  CookieSceneView.swift
//  Cookie
//
//  Draws a 3D scene (`CookieScene`) with RealityKit's RealityView (macOS 15)
//  on Cookie's paper card: the parts lit by a soft studio light, framed from
//  the scene's own size, labelled with paper pills and hand-inked leader lines
//  drawn in SwiftUI at each part's projected point (RealityView's in-scene
//  attachments are visionOS-only). Dragging turns the model, scrolling zooms.
//  A model that works (`CookieSceneMotion`) runs, slows and steps; its flows
//  run beads along their route; the camera flies to frame a part or a preset
//  view on a spring and gives way whenever the person turns or zooms. A soft
//  contact shadow sits under the model; cut parts are x-rays with a lit edge,
//  and isolate fades the rest back instead of hiding it.
//  `CookieScenePresenter` floats it like a card: one at a time, beside the
//  notch or the marks, click-through except while the pointer is over it.
//  `CookieSceneDirector` runs the scene's beats on the speech clock, each once,
//  in order, as the voice reaches its words.
//
//  The scene sits on the paper whether or not RealityView draws its own
//  background: the view's background style is the paper, and the card is
//  rounded around it either way.
//

import AppKit
import RealityKit
import SwiftUI

/// The live scene: its entities, camera and lights, how far it's turned and zoomed, what moves and
/// where each shown label's part is on the view. Built once per scene; dropped with the panel.
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
    /// The soft contact shadow under the model; it stays level as the model turns.
    let shadow = Entity()
    /// Flow beads (or, with Reduce Motion, still arrows), turned with the model.
    let flowLayer = Entity()
    private var markers: [String: [ModelEntity]] = [:]
    private var flowPaths: [String: CookieFlowPath] = [:]

    /// The labelled parts whose labels are showing (a beat may show any of them, in any order).
    @Published private(set) var shownLabelIDs: Set<String> = []
    var shownLabels: Int { shownLabelIDs.count }
    /// The showing labels' parts, in `scene.labelled` order (which keeps each on its rail).
    var shownLabelled: [CookieScene.Part] { scene.labelled.filter { shownLabelIDs.contains($0.id) } }
    /// Each shown label's part, projected onto the view (view points, top-left origin).
    @Published private(set) var anchors: [String: CGPoint] = [:]
    /// The scene's centre on the view; labels lean away from it.
    @Published private(set) var middle: CGPoint?

    /// Called on a drag or scroll, so the presenter keeps the scene up while it's being looked at.
    var onInteract: () -> Void = {}

    private let reduceMotion: Bool
    private(set) var spinning: Bool
    /// Radians a second while spinning; "faster" and "slower" move it within `spinRates`.
    private(set) var spinRate = CookieSceneStage.defaultSpinRate
    private(set) var turn = CookieSceneCamera.turn
    /// A spoken turn in progress: where it started, how far it goes, how long it has run.
    private var yawTurn: (base: simd_quatf, degrees: Float, elapsed: Float)?
    /// Every label shows at once ("label everything"), past the usual six.
    @Published private(set) var allLabels = false
    /// No labels at all ("hide labels"); the parts still light up as Cookie names them.
    @Published private(set) var labelsHidden = false
    private var dragBase: simd_quatf?
    private var zoom: Float = 1
    @Published private(set) var exploded = false
    private var subscription: EventSubscription?
    private var initialExplosionStarted = false
    private var explosionTask: Task<Void, Never>?
    /// 0 assembled, 1 exploded; eased between by `explosion`.
    private(set) var explosionBlend: Float = 0
    private var explosion: (from: Float, to: Float, elapsed: Float)?

    // Motion: the machine working.
    /// The joints are turning and the beads flowing.
    @Published private(set) var playing: Bool
    /// Running at `slowFactor` of its speed.
    @Published private(set) var slowMotion = false
    /// Seconds of motion so far (slow motion counts slowly); a step adds a twelfth of a turn.
    private(set) var motionTime: Float = 0
    /// Steps taken with Reduce Motion on, where the pose moves only a step at a time.
    private(set) var steps = 0
    @Published private(set) var flowsOn: Set<String>
    /// Parts drawn as a cutaway: see-through with a lit edge.
    @Published private(set) var cutParts: Set<String>
    /// The parts kept bright by "isolate"; the rest fade back. Nil: everything shows.
    private(set) var isolated: Set<String>?
    private var highlighted: Set<String> = []
    private var opacity: [String: Float] = [:]
    private var poseDirty = true
    private var pathsDirty = true
    private var shadowTurn: simd_quatf?
    private var rig: CookieSceneCameraRig

    private static let fieldOfView = CookieSceneCamera.fieldOfView
    static let defaultSpinRate: Float = 0.35
    static let spinRates: ClosedRange<Float> = 0.1...1.6
    /// Each "faster" or "slower" multiplies or divides the rate by this.
    static let spinFactor: Float = 1.6
    /// Slow motion runs the machine at this fraction of its speed.
    static let slowFactor: Float = 0.25
    /// How faint the parts "isolate" leaves out become.
    static let fadedOpacity: Float = 0.12
    static let explodeSeconds: Float = 1.2
    /// How long a spoken turn takes, eased in and out; longer turns take a little longer.
    static func turnSeconds(_ degrees: Float) -> Float { 0.45 + min(abs(degrees), 360) / 360 * 0.55 }

    init(scene: CookieScene, reduceMotion: Bool) {
        self.scene = scene
        self.reduceMotion = reduceMotion
        self.spinning = scene.spin && !reduceMotion
        playing = scene.run
        flowsOn = Set(scene.flows.filter(\.on).map(\.id))
        cutParts = Set(scene.parts.filter(\.cut).map(\.id))
        rig = CookieSceneCameraRig(overview: simd_length(CookieSceneCamera.eye(radius: CookieSceneCamera.radius(scene, exploded: false))))
        let studio = Self.studioLight()
        for part in scene.parts {
            let entity = ModelEntity(mesh: Self.mesh(part), materials: [Self.material(part, cut: part.cut)])
            entity.position = scene.place(of: part, exploded: false)
            entity.orientation = part.orientation
            if let studio { entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: studio)) }
            root.addChild(entity)
            parts[part.id] = entity
            Self.setRim(entity, part: part, on: part.cut)
        }
        root.addChild(flowLayer)
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
        Self.buildShadow(shadow)
        buildFlows()
        layout()
        placeShadow()
        placeCamera(instantly: true)
    }

    /// Puts the scene into the RealityView and starts the per-frame update (motion, camera, labels).
    func install(in content: inout RealityViewCameraContent) {
        subscription?.cancel()
        content.camera = .virtual
        content.add(root)
        content.add(shadow)
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
        flowLayer.children.removeAll()
        shadow.children.removeAll()
        parts = [:]
        markers = [:]
        lights = []
    }

    // MARK: Beats

    /// Beat 0 is the scene itself (an exploding scene comes apart a moment after it appears); beat n
    /// shows the first n labels. `all` shows everything at once.
    func reveal(through beat: Int, all: Bool) {
        let count = all ? scene.labelled.count : min(scene.labelled.count, beat)
        shownLabelIDs.formUnion(scene.labelled.prefix(count).map(\.id))
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
        light(id, members: [id], hand: hand)
    }

    /// Lights `members` (the active one `id`), brings back any of them isolate faded, and lets the hand follow.
    private func light(_ id: String, members: Set<String>, hand: Bool) {
        collapsed = false
        handFollows = hand
        activePart = id
        selectedPart = id
        if isolated != nil { isolated?.formUnion(members) }
        spinning = false
        if scene.labelled.contains(where: { $0.id == id }) { shownLabelIDs.insert(id) }
        highlighted = members
        refreshMaterials()
        if hand, let anchor = anchors[id] { onFocus(anchor) }
    }

    /// [VISUAL:focus:part]: the camera flies to frame the part (or its whole group), which lights up
    /// while the hand follows it. Nothing happens for a name the model doesn't have.
    func frame(_ name: String) {
        guard let resolved = Self.match(name, in: scene.parts.map(\.id) + scene.parts.compactMap(\.group)).flatMap(scene.resolve) else { return }
        let members = scene.parts(named: resolved)
        guard let first = members.first else { return }
        light(members.first { $0.label != nil }?.id ?? first.id, members: Set(members.map(\.id)), hand: true)
        // Mid-explosion (a beat that explodes, then focuses) the camera aims where the parts are going.
        let pose = scene.moves ? CookieSceneMotion.pose(scene, turns: currentTurns) : [:]
        func at(_ part: CookieScene.Part) -> SIMD3<Float> {
            explosion == nil ? parts[part.id]?.position ?? scene.place(of: part, exploded: exploded)
                : CookieSceneMotion.placed(scene, part, pose: pose, explosion: exploded ? 1 : 0).position
        }
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
        for part in members {
            low = simd_min(low, at(part) - part.reach)
            high = simd_max(high, at(part) + part.reach)
        }
        let centre = (low + high) / 2
        let radius = members.map { simd_length(at($0) - centre) + $0.reach }.max() ?? 0.1
        let overview = overviewDistance
        rig.frame(centre, turn: turn, distance: min(overview, max(overview * 0.3, CookieSceneCameraRig.distance(radius: radius))),
                  instantly: reduceMotion)
        updateCamera()
    }

    /// One beat of the scene's timeline: its actions in order, so the camera, the light, the hand,
    /// the labels and the motion all move on together from the same words.
    func perform(_ beat: CookieScene.Beat) {
        for action in beat.actions {
            switch action {
            case .command(let command):
                apply(command)
            case .isolate(let name):
                let members = scene.parts(named: name)
                guard let first = members.first else { continue }
                light(members.first { $0.label != nil }?.id ?? first.id, members: Set(members.map(\.id)), hand: true)
                isolated = Set(members.map(\.id))
                onInteract()
            case .label(let name):
                shownLabelIDs.formUnion(scene.parts(named: name).filter { $0.label != nil }.map(\.id))
                onInteract()
            }
        }
    }

    func pauseTeaching() {
        explosionTask?.cancel()
        explosionTask = nil
        handFollows = false
        activePart = nil
        CookieHand.shared.stopTeaching(owner: teachingOwner)
        highlighted = []
        refreshMaterials()
    }

    private func explodeParts(animated: Bool) {
        let target: Float = exploded ? 1 : 0
        if animated, target != explosionBlend {
            explosion = (from: explosionBlend, to: target, elapsed: 0)
        } else {
            explosion = nil
            explosionBlend = target
            poseDirty = true
            pathsDirty = true
            layout()
        }
    }

    func apply(_ command: CookieVisualCommand) {
        collapsed = false
        switch command {
        case .spin(let change):
            // Reduce Motion keeps the model still: it only turns when asked to, step by step.
            spinRate = Self.spinRate(change, from: spinning ? spinRate : Self.defaultSpinRate)
            spinning = change != .stop && !reduceMotion
            onInteract()
            return
        case .labels(let shown):
            labelsHidden = !shown
            allLabels = shown
            if shown { shownLabelIDs = Set(scene.labelled.map(\.id)) }
            onInteract()
            return
        case .rotate(let degrees):
            spinning = false
            rotate(by: degrees)
            onInteract()
            return
        case .run, .slow:
            // With Reduce Motion the machine holds a still pose; a step moves it on.
            playing = scene.hasMotion
            slowMotion = command == .slow
            onInteract()
            return
        case .stop:
            playing = false
            onInteract()
            return
        case .step:
            playing = false
            if reduceMotion { steps += 1 } else { motionTime += CookieSceneMotion.stepSeconds(scene) }
            poseDirty = true
            layout()
            onInteract()
            return
        case .flow(let id, let on):
            guard let flow = Self.match(id, in: scene.flows.map(\.id)) else { return }
            if on { flowsOn.insert(flow) } else { flowsOn.remove(flow) }
            // Re-lay the route: Reduce Motion's still arrows are placed only then, and a flow that
            // started hidden never was.
            pathsDirty = true
            updateFlows()
            onInteract()
            return
        case .cut(let name, let on):
            guard let resolved = Self.match(name, in: scene.parts.map(\.id) + scene.parts.compactMap(\.group)).flatMap(scene.resolve) else { return }
            let members = Set(scene.parts(named: resolved).map(\.id))
            if on { cutParts.formUnion(members) } else { cutParts.subtract(members) }
            refreshMaterials()
            onInteract()
            return
        case .view(let view):
            rig.show(view, turn: turn, overview: overviewDistance, instantly: reduceMotion)
            updateCamera()
            onInteract()
            return
        case .focus(let name):
            frame(name)
            onInteract()
            return
        default: break
        }
        explosionTask?.cancel()
        explosionTask = nil
        initialExplosionStarted = true
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
            // A grouped part isolates with its group; the rest fade back rather than vanish.
            guard let selectedPart else { return }
            isolated = scene.members(of: selectedPart)
        case .showAll:
            isolated = nil
        case .zoomIn: zoom(by: 20)
        case .zoomOut: zoom(by: -20)
        case .reset:
            isolated = nil
            exploded = false
            explodeParts(animated: !reduceMotion)
            zoom = 1
            yawTurn = nil
            spinRate = Self.defaultSpinRate
            turn = CookieSceneCamera.turn
            root.orientation = turn
            playing = scene.run
            slowMotion = false
            motionTime = 0
            steps = 0
            flowsOn = Set(scene.flows.filter(\.on).map(\.id))
            cutParts = Set(scene.parts.filter(\.cut).map(\.id))
            poseDirty = true
            layout()
            updateFlows()
            placeCamera()
            pauseTeaching()
        case .rotate, .spin, .labels, .run, .slow, .stop, .step, .flow, .cut, .view, .focus: break
        }
        onInteract()
    }

    /// A name from a [VISUAL:…] verb (lowercased on the way in) matched to one the scene has.
    static func match(_ name: String, in names: [String]) -> String? {
        let given = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return names.first { $0 == given } ?? names.first { $0.lowercased() == given.lowercased() }
            ?? names.first { CookieScene.fold($0) == CookieScene.fold(given) && !CookieScene.fold(given).isEmpty }
    }

    /// The next spin rate, always inside `spinRates`. Stopping keeps the rate for the next start.
    static func spinRate(_ change: CookieVisualCommand.Spin, from rate: Float) -> Float {
        let next: Float = switch change {
        case .faster: rate * spinFactor
        case .slower: rate / spinFactor
        case .start, .stop: rate
        }
        return min(spinRates.upperBound, max(spinRates.lowerBound, next))
    }

    /// Smooth start, smooth stop (cubic ease in and out), for t in 0…1.
    static func eased(_ t: Float) -> Float {
        let t = min(1, max(0, t))
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// `base` turned about the vertical (world y) axis by `degrees` × `progress`, the way spinning
    /// and dragging sideways turn it.
    static func yawed(_ base: simd_quatf, degrees: Float, progress: Float) -> simd_quatf {
        simd_quatf(angle: degrees * progress * .pi / 180, axis: [0, 1, 0]) * base
    }

    /// Starts a spoken turn. A turn asked for mid-turn carries on from where the model is, with
    /// what was left of the first turn added, so "left, left" ends 90° round without a jump.
    private func rotate(by degrees: Float) {
        var total = degrees
        if let current = yawTurn {
            let seconds = Self.turnSeconds(current.degrees)
            total += current.degrees * (1 - Self.eased(current.elapsed / seconds))
        }
        if reduceMotion {
            yawTurn = nil
            turn = Self.yawed(turn, degrees: total, progress: 1)
            root.orientation = turn
        } else {
            yawTurn = (base: turn, degrees: total, elapsed: 0)
        }
    }

    // MARK: Turning and zooming

    func drag(_ translation: CGSize) {
        yawTurn = nil
        let base = dragBase ?? turn
        dragBase = base
        spinning = false // the person has taken over
        rig.hold() // and the camera stops where it is until the next beat
        let yaw = Float(translation.width) * 0.01, pitch = Float(translation.height) * 0.01
        turn = simd_quatf(angle: pitch, axis: [1, 0, 0]) * simd_quatf(angle: yaw, axis: [0, 1, 0]) * base
        root.orientation = turn
        onInteract()
    }

    func endDrag() {
        dragBase = nil
    }

    /// A scroll's vertical delta; up comes closer. The person's zoom sits on top of every camera move.
    func zoom(by delta: CGFloat) {
        zoom = min(3, max(0.5, zoom * Float(exp(Double(delta) * 0.01))))
        rig.hold()
        updateCamera()
        onInteract()
    }

    /// How far back the whole model fits the view's height (`CookieSceneCamera`, which the build check
    /// sees through too).
    private var overviewDistance: Float {
        simd_length(CookieSceneCamera.eye(radius: CookieSceneCamera.radius(scene, exploded: exploded)))
    }

    /// Back to the whole model, a little from above: a camera move, or a cut with Reduce Motion.
    private func placeCamera(instantly: Bool = false) {
        rig.show(.overview, turn: turn, overview: overviewDistance, instantly: instantly || reduceMotion)
        updateCamera()
    }

    private func updateCamera() {
        camera.look(at: rig.target, from: rig.eye(zoom: zoom), relativeTo: nil)
    }

    /// Where the camera is and what it looks at, for checks.
    var cameraShot: (eye: SIMD3<Float>, target: SIMD3<Float>, settled: Bool) { (rig.eye(zoom: zoom), rig.target, rig.isSettled) }

    /// One frame: the machine's motion, the explosion, fades, the camera; then a spoken turn in
    /// progress, else the spin (neither while the person is dragging).
    func step(_ seconds: Float) {
        if playing, scene.hasMotion, !reduceMotion {
            motionTime += seconds * (slowMotion ? Self.slowFactor : 1)
            poseDirty = poseDirty || scene.moves
            updateFlows()
        }
        if var current = explosion {
            current.elapsed += seconds
            explosionBlend = current.from + (current.to - current.from) * Self.eased(current.elapsed / Self.explodeSeconds)
            explosion = current.elapsed >= Self.explodeSeconds ? nil : current
            poseDirty = true
            pathsDirty = true
        }
        fade(seconds)
        if poseDirty { layout() }
        if pathsDirty { updateFlows() }
        if dragBase == nil {
            if var current = yawTurn {
                current.elapsed += seconds
                let duration = Self.turnSeconds(current.degrees)
                turn = Self.yawed(current.base, degrees: current.degrees, progress: Self.eased(current.elapsed / duration))
                yawTurn = current.elapsed >= duration ? nil : current
                root.orientation = turn
            } else if spinning {
                turn = simd_quatf(angle: seconds * spinRate, axis: [0, 1, 0]) * turn
                root.orientation = turn
            }
        }
        if !rig.isSettled || rig.subject != nil {
            rig.step(seconds, turn: turn)
            updateCamera()
        }
        if shadowTurn.map({ abs(simd_dot($0.vector, turn.vector)) < 0.99999 }) ?? true { placeShadow() }
    }

    private func frame(_ seconds: Float, project: (SIMD3<Float>) -> CGPoint?) {
        step(seconds)
        if handFollows, let activePart, let entity = parts[activePart], !shownLabelIDs.contains(activePart),
           let point = project(entity.position(relativeTo: nil)) {
            // A part without a showing label (a focus on a group, an unlabelled part): the hand still follows it.
            onFocus(point)
        }
        guard !shownLabelIDs.isEmpty else { return }
        var points: [String: CGPoint] = [:]
        for part in shownLabelled where !isFaded(part.id) {
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

    // MARK: Motion

    /// The joints' turns now: running time, or Reduce Motion's still pose.
    var currentTurns: [String: Float] {
        reduceMotion ? CookieSceneMotion.representative(scene, steps: steps) : CookieSceneMotion.turns(scene, time: motionTime)
    }

    /// Where every part is placed and turned on the stage, about the centroid.
    func placement(of id: String) -> CookieSceneMotion.Placement? {
        parts[id].map { .init(position: $0.position, orientation: $0.orientation) }
    }

    /// Puts every part where the motion and the explosion have it.
    private func layout() {
        let pose = scene.moves ? CookieSceneMotion.pose(scene, turns: currentTurns) : [:]
        for part in scene.parts {
            guard let entity = parts[part.id] else { continue }
            let placed = CookieSceneMotion.placed(scene, part, pose: pose, explosion: explosionBlend)
            entity.position = placed.position
            entity.orientation = placed.orientation
        }
        poseDirty = false
        shadowTurn = nil
    }

    // MARK: Flows

    /// The bead pool (or Reduce Motion's arrows), made once: nothing is created while it runs.
    private func buildFlows() {
        guard !scene.flows.isEmpty else { return }
        let radius = CookieSceneCamera.radius(scene, exploded: false)
        let paths = scene.flows.map { CookieSceneMotion.path(scene, $0, explosion: 0) }
        let counts = CookieSceneMotion.beadCounts(scene, lengths: paths.map(\.length))
        let bead = MeshResource.generateSphere(radius: min(0.04, max(0.003, radius * 0.014)))
        let arrow = CookieMeshResources.mesh(CookieScene.Form(.arrow, ["length": radius * 0.16, "radius": radius * 0.013]))
        for (index, flow) in scene.flows.enumerated() {
            let material = Self.glow(flow.tint)
            let count = reduceMotion ? min(10, max(3, Int(paths[index].length / max(0.01, radius * 0.3)))) : counts[index]
            markers[flow.id] = (0..<count).map { _ in
                let entity = ModelEntity(mesh: reduceMotion ? arrow : bead, materials: [material])
                flowLayer.addChild(entity)
                return entity
            }
        }
        pathsDirty = true
        updateFlows()
    }

    /// Moves the beads along their paths (and re-lays the arrows when the paths move).
    private func updateFlows() {
        guard !scene.flows.isEmpty else { return }
        if pathsDirty {
            for flow in scene.flows { flowPaths[flow.id] = CookieSceneMotion.path(scene, flow, explosion: explosionBlend) }
        }
        let relay = pathsDirty
        pathsDirty = false
        for flow in scene.flows {
            guard let entities = markers[flow.id], let path = flowPaths[flow.id] else { continue }
            let on = flowsOn.contains(flow.id)
            for (index, entity) in entities.enumerated() {
                entity.isEnabled = on
                guard on else { continue }
                if reduceMotion {
                    guard relay else { continue }
                    // Still arrows, evenly along the route, each pointing the way it goes.
                    let s = (Float(index) + 0.5) / Float(entities.count) * path.length
                    let (a, b) = path.across(at: s)
                    let angle = Float(index) * 2.1
                    entity.position = path.point(at: s) + (a * cos(angle) + b * sin(angle)) * flow.spread * 0.7
                    entity.orientation = simd_quatf(from: [0, 1, 0], to: path.tangent(at: s))
                } else {
                    let bead = CookieSceneMotion.bead(index, of: entities.count, flow: flow, path: path, time: motionTime)
                    entity.position = path.point(at: bead.s) + bead.offset
                    entity.scale = SIMD3(repeating: max(0.05, bead.fade))
                }
            }
        }
    }

    /// Where each showing flow's markers are, for checks.
    func markerPositions(_ flow: String) -> [SIMD3<Float>] { (markers[flow] ?? []).filter(\.isEnabled).map(\.position) }

    // MARK: Looks

    /// Whether isolate has faded this part back.
    func isFaded(_ id: String) -> Bool { isolated.map { !$0.contains(id) } ?? false }

    /// Eases each part's opacity toward bright or faded (at once with Reduce Motion).
    private func fade(_ seconds: Float) {
        for part in scene.parts {
            guard let entity = parts[part.id] else { continue }
            let target: Float = isFaded(part.id) ? Self.fadedOpacity : 1
            let current = opacity[part.id] ?? 1
            guard current != target else { continue }
            var next = reduceMotion ? target : current + (target - current) * min(1, 1 - exp(-seconds * 9))
            if abs(next - target) < 0.01 { next = target }
            opacity[part.id] = next
            if next >= 1 { entity.components.remove(OpacityComponent.self) } else { entity.components.set(OpacityComponent(opacity: next)) }
        }
    }

    /// Each part's material for its tint, finish, cutaway and whether it's lit as the one being explained.
    private func refreshMaterials() {
        for part in scene.parts {
            guard let entity = parts[part.id] else { continue }
            let cut = cutParts.contains(part.id)
            var material = Self.material(part, cut: cut)
            if highlighted.contains(part.id) { material.baseColor = .init(tint: NSColor.systemOrange) }
            entity.model?.materials = [material]
            Self.setRim(entity, part: part, on: cut)
        }
    }

    /// A cut part's lit edge: the same shape a touch larger, drawn from behind only, so just its
    /// silhouette and rims show round the see-through part.
    private static func setRim(_ entity: ModelEntity, part: CookieScene.Part, on: Bool) {
        let existing = entity.children.first { $0.name == "rim" }
        guard on else { existing?.removeFromParent(); return }
        guard existing == nil, let mesh = entity.model?.mesh else { return }
        var rim = UnlitMaterial(color: NSColor(red: 1, green: 0.9, blue: 0.72, alpha: 1))
        rim.blending = .transparent(opacity: .init(floatLiteral: 0.55))
        rim.faceCulling = .front
        let edge = ModelEntity(mesh: mesh, materials: [rim])
        edge.name = "rim"
        edge.scale = SIMD3(repeating: 1 + min(0.04, max(0.01, 0.006 / max(0.05, part.reach))))
        entity.addChild(edge)
    }

    /// The contact shadow: stacked soft discs, each a little wider and fainter, so the edge feathers out.
    private static func buildShadow(_ shadow: Entity) {
        let rings = 7
        for k in 0..<rings {
            var material = UnlitMaterial(color: NSColor(red: 0.16, green: 0.12, blue: 0.09, alpha: 1))
            material.blending = .transparent(opacity: .init(floatLiteral: 0.055))
            let disc = ModelEntity(mesh: .generateCylinder(height: 0.0002, radius: 0.45 + 0.55 * Float(k) / Float(rings - 1)), materials: [material])
            disc.position.y = Float(rings - k) * 0.0003
            shadow.addChild(disc)
        }
    }

    /// Lays the shadow under the model as it's turned now: just below its lowest point, as wide as it is.
    private func placeShadow() {
        shadowTurn = turn
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
        for part in scene.parts where !isFaded(part.id) {
            guard let entity = parts[part.id] else { continue }
            let box = part.form.bounds
            for corner in 0..<8 {
                let q = SIMD3<Float>(corner & 1 == 0 ? box.min.x : box.max.x, corner & 2 == 0 ? box.min.y : box.max.y, corner & 4 == 0 ? box.min.z : box.max.z)
                let world = turn.act(entity.position + entity.orientation.act(q))
                low = simd_min(low, world)
                high = simd_max(high, world)
            }
        }
        guard low.x <= high.x else { return }
        let radius = CookieSceneCamera.radius(scene, exploded: exploded)
        shadow.position = [(low.x + high.x) / 2, low.y - radius * 0.02, (low.z + high.z) / 2]
        shadow.scale = [(high.x - low.x) * 0.6 + radius * 0.1, 1, (high.z - low.z) * 0.6 + radius * 0.1]
    }

    /// Where the shadow lies, for checks.
    var shadowPlacement: (centre: SIMD3<Float>, scale: SIMD3<Float>) { (shadow.position, shadow.scale) }

    // MARK: Building

    /// The part's shape from the parts library (`CookieMeshes`), usually already warmed off the main thread.
    private static func mesh(_ part: CookieScene.Part) -> MeshResource {
        CookieMeshResources.mesh(part.form)
    }

    /// How rough and how metal each tint is, before its finish.
    static func surface(_ tint: CookieScene.Tint) -> (roughness: Float, metallic: Float) {
        switch tint {
        case .amber: (0.45, 0)
        case .cream: (0.7, 0)
        case .graphite: (0.55, 0.2)
        case .sky, .mint, .rose: (0.5, 0)
        case .steel: (0.3, 0.9)
        case .glass: (0.05, 0)
        case .copper: (0.32, 1)
        case .brass: (0.3, 1)
        case .rubber: (0.92, 0)
        case .plasticWhite: (0.38, 0)
        case .carbon: (0.3, 0.15)
        }
    }

    /// The tint's roughness under a finish: matte roughens, polished smooths (and lacquers what isn't metal).
    static func finished(_ tint: CookieScene.Tint, _ finish: CookieScene.Finish?) -> (roughness: Float, metallic: Float, clearcoat: Float) {
        let (roughness, metallic) = surface(tint)
        switch finish ?? .satin {
        case .matte: return (min(1, roughness + 0.35), metallic, 0)
        case .satin: return (roughness, metallic, tint == .carbon ? 0.8 : 0)
        case .polished: return (max(0.04, roughness * 0.3), metallic, metallic < 0.5 ? 0.7 : 0)
        }
    }

    private static func material(_ part: CookieScene.Part, cut: Bool) -> PhysicallyBasedMaterial {
        let rgb = CookieScene.rgb(part.tint)
        let (roughness, metallic, clearcoat) = finished(part.tint, part.finish)
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: NSColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1))
        material.roughness = .init(floatLiteral: roughness)
        material.metallic = .init(floatLiteral: metallic)
        if clearcoat > 0 {
            material.clearcoat = .init(floatLiteral: clearcoat)
            material.clearcoatRoughness = .init(floatLiteral: 0.08)
        }
        // A cut part is see-through so what's inside shows, with a faint x-ray glow; glass always is see-through.
        let opacity: Float = part.tint == .glass ? 0.28 : cut ? 0.26 : 1
        if opacity < 1 {
            material.blending = .transparent(opacity: .init(floatLiteral: opacity))
            material.faceCulling = .none
        }
        if cut {
            material.emissiveColor = .init(color: NSColor(red: 0.55, green: 0.75, blue: 0.95, alpha: 1))
            material.emissiveIntensity = 0.25
        }
        return material
    }

    /// A flow's beads glow in their tint, a little lifted toward white so they read against the parts.
    private static func glow(_ tint: CookieScene.Tint) -> UnlitMaterial {
        let rgb = simd_mix(CookieScene.rgb(tint), SIMD3(repeating: 1), SIMD3(repeating: 0.3))
        return UnlitMaterial(color: NSColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1))
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

    static let sceneSize = CookieSceneCamera.viewport

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
                HStack(spacing: stage.scene.hasMotion ? 12 : 16) {
                    Button(stage.exploded ? "Assemble" : "Explode") { stage.apply(stage.exploded ? .assemble : .explode) }
                    Button("Previous") { stage.apply(.previous) }
                    Button("Next part") { stage.apply(.next) }
                    Button("Reset") { stage.apply(.reset) }
                    Spacer(minLength: 0)
                    if stage.scene.hasMotion {
                        // With Reduce Motion the machine holds still; stepping moves it on a twelfth of a turn.
                        if reduceMotion {
                            Button("Step") { stage.apply(.step) }
                                .accessibilityHint("Moves the machine on a twelfth of a turn")
                        } else {
                            Button(stage.playing ? "Stop" : "Run") { stage.apply(stage.playing ? .stop : .run) }
                                .accessibilityHint(stage.playing ? "Stops the machine" : "Sets the machine working")
                            Button(stage.slowMotion && stage.playing ? "Full speed" : "Slow") { stage.apply(stage.slowMotion && stage.playing ? .run : .slow) }
                                .accessibilityHint("Runs the machine in slow motion, or back at full speed")
                        }
                    }
                    Button { stage.apply(.rotate(degrees: -CookieVisualCommand.rotateStep)) } label: { Image(systemName: "arrow.counterclockwise") }
                        .accessibilityLabel("Turn left")
                    Button { stage.apply(.rotate(degrees: CookieVisualCommand.rotateStep)) } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Turn right")
                        .padding(.trailing, 4)
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
        let available = stage.labelsHidden ? [] : stage.shownLabelled
        let recent = Array(available.filter { $0.id != stage.activePart }.suffix(stage.activePart == nil ? 6 : 5))
        let visible = available.count <= 6 || stage.allLabels ? available : available.filter { part in recent.contains(where: { $0.id == part.id }) || part.id == stage.activePart }
        let shown = Array(visible.enumerated())
        let crowded = shown.count > 6
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
                        .font(.system(size: crowded ? 10 : 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(stage.activePart == part.id ? CookieMarksLayer.ink : inkText)
                        .fontWeight(stage.activePart == part.id ? .bold : .medium)
                        .lineLimit(crowded ? 1 : 2)
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: stage.shownLabelIDs)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: stage.labelsHidden)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: stage.allLabels)
    }

    private func unit(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / size.width, y: point.y / size.height)
    }
}

/// Stable rails keep labels apart while their leader lines follow the rotating geometry.
enum CookieSceneLabelLayout {
    static func centre(index: Int, count: Int, size: CGSize) -> CGPoint {
        let row = index / 2
        let rows = max(1, (count + 1) / 2)
        // Up to six labels sit well inside the view; every label at once ("label everything")
        // uses nearly its full height, one line each.
        let margin: CGFloat = count > 6 ? 22 : 74
        return CGPoint(x: index % 2 == 0 ? 78 : size.width - 78,
                       y: margin + CGFloat(row) * (size.height - 2 * margin) / CGFloat(max(1, rows - 1)))
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
    private(set) var stage: CookieSceneStage?
    private var schedules: [CookieSpeechClock.Scheduled] = []
    private weak var clock: CookieSpeechClock?
    private var monitors: [Any] = []
    private var fadeTimer: Task<Void, Never>?
    private var lastActive = Date()

    var teachingContext: String? {
        stage.map { Self.teachingContext($0) + (director.notes.isEmpty ? "" : ". Beats whose words you didn't say, placed evenly: " + director.notes.joined(separator: "; ")) }
    }
    static func teachingContext(_ stage: CookieSceneStage) -> String {
        "Visible 3D model: \(stage.scene.title). Selected: \(stage.selectedPart ?? "none"). Exploded: \(stage.exploded). Spinning: \(stage.spinning). Labels: \(stage.labelsHidden ? "hidden" : "shown"). Parts: " + stage.scene.labelled.map { "\($0.id)=\($0.label ?? $0.id)" }.joined(separator: "; ")
            + (stage.scene.hasMotion ? ". Motion: \(stage.playing ? (stage.slowMotion ? "slow motion" : "running") : "stopped")" : "")
            + (stage.scene.flows.isEmpty ? "" : ". Flows: " + stage.scene.flows.map { "\($0.id) \(stage.flowsOn.contains($0.id) ? "on" : "off")" }.joined(separator: ", "))
            + (stage.cutParts.isEmpty ? "" : ". Cut: " + stage.cutParts.sorted().joined(separator: ", "))
    }
    /// A model is up (shown or folded).
    var isShowing: Bool { stage != nil }
    /// Open and used just now (`CookieLessonIdle.inUse`): spoken commands like "faster" are its.
    var inUse: Bool { stage.map { CookieLessonIdle.inUse(collapsed: $0.collapsed, idle: Date().timeIntervalSince(lastActive)) } ?? false }
    /// Called when a scene appears, so whatever stood in for it ("Building your model…") can go.
    var onShow: (() -> Void)?
    /// A lesson the person asked for from their screen closes on Esc wherever the pointer is
    /// (when it's the newest Cookie surface: `CookieEscape`).
    var escapeAnywhere = false {
        didSet { escapeAnywhere ? CookieEscape.shared.push(.scene) : CookieEscape.shared.pop(.scene) }
    }
    func pauseTeaching() { cancelSchedules(); stage?.pauseTeaching() }
    @discardableResult func apply(_ command: CookieVisualCommand) -> Bool {
        guard let stage else { return false }
        stage.apply(command)
        lastActive = Date()
        return true
    }
    @discardableResult func focus(_ id: String) -> Bool {
        guard let stage, stage.scene.labelled.contains(where: { $0.id == id }) else { return false }
        stage.focus(id)
        restartFadeTimer()
        return true
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Runs the scene's beats at their words.
    let director = CookieSceneDirector()

    /// A streamed reply's scene, as its tag arrives: it appears when the voice reaches the tag, and its
    /// beats go on the clock from the words streamed by then (the rest when the reply is whole).
    func prepare(_ scene: CookieScene, clock: CookieSpeechClock) {
        cancelSchedules()
        CookieMeshResources.warm(scene)
        self.clock = clock
        director.reset()
        if scene.beats.isEmpty {
            schedules.append(clock.schedule(atOffset: scene.offset) { [weak self] in
                _ = self?.show(scene, near: nil)
            })
        } else {
            scheduleShow(scene, near: nil, clock: clock)
        }
    }

    /// Puts the scene on the speech clock: it appears at its tag; then its beats run at their words,
    /// or (without beats) its labels follow the sentence after it. Call once the reply is whole.
    func schedule(_ scene: CookieScene, spoken: String, near region: (rect: CGRect, display: CGRect)?, clock: CookieSpeechClock) {
        CookieMeshResources.warm(scene)
        if !scene.beats.isEmpty {
            if let stage, stage.scene == scene, self.clock === clock {
                director.finish(spoken: spoken)
                director.schedule(scene, on: stage, clock: clock)
            } else {
                cancelSchedules()
                self.clock = clock
                director.reset()
                director.finish(spoken: spoken)
                scheduleShow(scene, near: region, clock: clock)
            }
            return
        }
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

    /// The scene at its tag (and, with beats, the explosion it starts with); then its beats.
    private func scheduleShow(_ scene: CookieScene, near region: (rect: CGRect, display: CGRect)?, clock: CookieSpeechClock) {
        schedules.append(clock.schedule(atOffset: scene.offset) { [weak self] in
            guard let self else { return }
            let stage = self.show(scene, near: region)
            stage.reveal(through: 0, all: false)
            self.director.schedule(scene, on: stage, clock: clock)
            self.restartFadeTimer()
        })
    }

    /// A scene that isn't spoken (a typed answer): all of it now, its beats played through to their end state.
    func showNow(_ scene: CookieScene, near region: (rect: CGRect, display: CGRect)?) {
        cancelSchedules()
        director.reset()
        let shown = show(scene, near: region)
        shown.reveal(through: scene.labelled.count, all: true)
        scene.beats.forEach(shown.perform)
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
        director.reset()
        escapeAnywhere = false
    }

    // MARK: Showing

    private func cancelSchedules() {
        if let clock { schedules.forEach(clock.cancel) }
        schedules = []
        director.cancel()
    }

    @discardableResult
    private func show(_ scene: CookieScene, near region: (rect: CGRect, display: CGRect)?) -> CookieSceneStage {
        onShow?()
        if let stage, stage.scene == scene { return stage }
        let newStage = CookieSceneStage(scene: scene, reduceMotion: reduceMotion)
        newStage.onInteract = { [weak self] in self?.restartFadeTimer() }
        director.onBeat = { [weak self] in self?.restartFadeTimer() }
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
                let anywhere = self.escapeAnywhere ? CookieEscape.shared.claims(.scene, at: event.timestamp, local: local) : local
                if anywhere || self.cardRect.contains(NSEvent.mouseLocation) { self.dismiss() }
            }
        }
        if let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { escape($0, false) }) { monitors.append(keys) }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { escape($0, true); return $0 }) { monitors.append(keys) }
    }
}

/// A scene's beats on the speech clock, for the stage showing it. Each beat runs once, in order,
/// when the voice reaches its words. Until the reply is whole only beats whose place is already
/// certain (found in the words streamed so far, or between two found) wait on the clock; the rest
/// go on when `finish` gives the whole reply. An interruption (`cancel`, or the clock stopping)
/// leaves the model as the last beat left it.
@MainActor
final class CookieSceneDirector {
    private var schedules: [CookieSpeechClock.Scheduled] = []
    private weak var clock: CookieSpeechClock?
    /// How many beats have run.
    private(set) var ran = 0
    private var spoken: String?
    /// Beats whose words weren't in the reply, placed evenly; the next turn hears about them.
    private(set) var notes: [String] = []
    /// After each beat (the presenter keeps the model up).
    var onBeat: () -> Void = {}

    /// A new scene: nothing run, nothing known.
    func reset() {
        cancel()
        ran = 0
        spoken = nil
        notes = []
    }

    /// The whole reply's spoken words.
    func finish(spoken: String) { self.spoken = spoken }

    /// Puts every beat not yet run on the clock, against the whole reply when it's known and the
    /// words the voice has so far otherwise.
    func schedule(_ scene: CookieScene, on stage: CookieSceneStage, clock: CookieSpeechClock) {
        cancel()
        self.clock = clock
        let timeline = scene.timeline(in: spoken ?? clock.text)
        let known = spoken != nil ? scene.beats.count : (timeline.found.lastIndex(of: true).map { $0 + 1 } ?? 0)
        if spoken != nil { notes = timeline.notes }
        for index in min(ran, known)..<known {
            schedules.append(clock.schedule(atOffset: timeline.offsets[index]) { [weak self, weak stage] in
                guard let self, let stage, stage.scene == scene, index == self.ran else { return }
                self.ran += 1
                stage.perform(scene.beats[index])
                self.onBeat()
            })
        }
    }

    func cancel() {
        if let clock { schedules.forEach(clock.cancel) }
        schedules = []
    }
}

/// The scene answers the first click and drag even though Cookie isn't the active app.
private final class CookieSceneHostingView: NSHostingView<CookieSceneView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
