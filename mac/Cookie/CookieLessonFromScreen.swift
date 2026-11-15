//
//  CookieLessonFromScreen.swift
//  Cookie
//
//  Explain anything as a live 3D lesson. Point at something (an error, a
//  balance sheet, a pump diagram, a molecule) and say "show me this in 3D",
//  "explain this visually" or "make a model of this" (only words that ask for
//  a visual: "break it down" and "walk me through this" stay the guided
//  teaching they always were): Cookie takes one redacted picture of what is
//  pointed at (the circled area, else the part of the front window around
//  the pointer, else that window), and asks the model for exactly one visual
//  built from it: a SCENE for a physical thing, a CARD for an abstract one,
//  every label taken from the words in the picture or marked as general
//  knowledge. While the model works a small "Building your model…" card holds
//  the place; a visual Cookie's checks reject becomes an honest card saying so.
//
//  The model then answers to plain speech: "rotate left", "turn it around",
//  "spin faster", "stop spinning", "label everything", "hide labels" go
//  straight to the model on screen without a round trip when that's all that
//  was said; anything longer goes through the model, which has [VISUAL:…] for
//  the same commands and [TEACH:id] for "what does this part do?".
//

import AppKit
import SwiftUI

/// Where a lesson's picture comes from.
enum CookieLessonSource: Equatable {
    /// The area the person circled (⌃⌥ drag), already captured and redacted by the circle.
    case circle
    /// The part of the front window around the pointer, spoken while pointing.
    case pointer
    /// The front window, typed with the screen button (the pointer is on Cookie then).
    case window
    /// Typed about a selection, no screen button: the selected words are the source, no picture.
    case selection
}

/// One look at what's pointed at, for the lesson.
enum CookieLessonLook: Equatable {
    case picture(data: Data, hidden: Int, app: String, region: CGRect)
    /// Why Cookie didn't look; the lesson goes on from the words and says so.
    case refused(String)
}

/// Everything the lesson's look touches outside itself; the checks give it fakes.
struct CookieLessonEnvironment {
    var frontApp: @MainActor () -> CookieLayerTarget?
    /// The app's front window, AppKit global; nil when it has none.
    var windowFrame: @MainActor (pid_t) async -> CGRect?
    /// The display a rectangle (or a point, as a zero-size one) is on.
    var displayFrame: @MainActor (CGRect) -> CGRect?
    /// AppKit global.
    var pointer: @MainActor () -> CGPoint
    /// A blocked app, a password field or secure input: why Cookie must not look, or nil.
    var refusal: @MainActor (CookieLayerTarget) -> String?
    var screenAllowed: @MainActor () -> Bool
    /// The region as a redacted JPEG (the Proof `.saw` / `.redacted` rows are written by the capture).
    var capture: @MainActor (CGRect) async throws -> CompanionScreenCaptureUtility.RedactedJPEG?
}

extension CookieLessonEnvironment {
    @MainActor static func live(harness: HarnessClient, screenAllowed: @escaping @MainActor () -> Bool) -> Self {
        let layers = CookieLayerEnvironment.live(harness: harness)
        return Self(
            frontApp: layers.frontApp,
            windowFrame: layers.windowFrame,
            displayFrame: layers.displayFrame,
            pointer: { NSEvent.mouseLocation },
            refusal: layers.refusal,
            screenAllowed: screenAllowed,
            capture: { rect in try await CompanionScreenCaptureUtility.captureRegionAsJPEG(rect, feature: CookieLessonFromScreen.feature) }
        )
    }
}

enum CookieLessonFromScreen {
    /// The name on its Proof rows.
    static let feature = "3D lesson"
    /// Around the pointer: about a paragraph or a figure's worth, in points.
    static let pointerBox = CGSize(width: 900, height: 600)
    /// Smaller than this and the pointed area isn't worth a picture; the whole window is taken instead.
    static let minimumRegion = CGSize(width: 160, height: 100)
    static let captureSeconds = 8.0

    // MARK: Routing

    /// Only words that ask for a visual. "Break it down" and "walk me through this" are guided teaching
    /// (wait_for_step) and plain answers, as they always were: they never take a picture on their own.
    private static let phrases = [
        "in 3d", "in 3-d", "in three d", "3d model", "3d version", "visually", "visual explanation", "as a model",
        "a model of this", "a model of that", "a model of it", "a model of these", "model out of",
    ]

    static func normalised(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "[^\\p{L}\\p{N}'-]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The words ask for what's on screen as a visual.
    static func asks(_ text: String) -> Bool {
        let text = " " + normalised(text) + " "
        return phrases.contains { text.contains(" " + $0 + " ") }
    }

    /// The words point at something ("this", "that", "it", "here", "on my screen").
    static func refersToScreen(_ text: String) -> Bool {
        normalised(text).range(of: "\\b(this|that|these|those|it|here|screen)\\b", options: .regularExpression) != nil
    }

    /// Whether this request is a lesson from the screen, and where its picture comes from; nil leaves
    /// it to the usual routing. "Explain photosynthesis visually" points at nothing, so it isn't one;
    /// a typed request looks only with the screen button (the person decides, as always).
    static func source(_ text: String, selection: Bool, circled: Bool, screenGesture: Bool, spoken: Bool,
                       visualShowing: Bool) -> CookieLessonSource? {
        guard asks(text) else { return nil }
        if circled { return .circle }
        guard refersToScreen(text) else { return nil }
        if screenGesture { return spoken ? .pointer : .window }
        return selection ? .selection : nil
    }

    // MARK: Where to look

    /// The part of the screen a pointed lesson looks at (AppKit global): a box around the pointer, kept
    /// inside the front window and its display (slid in from an edge, not cut short); the whole window
    /// when the pointer is outside it or the window is small; around the pointer on its display when
    /// there is no window (the desktop).
    static func region(pointer: CGPoint, window: CGRect?, display: CGRect?) -> CGRect? {
        let box = CGRect(x: pointer.x - pointerBox.width / 2, y: pointer.y - pointerBox.height / 2,
                         width: pointerBox.width, height: pointerBox.height)
        if let window {
            let area = display.map { window.intersection($0) } ?? window
            guard !area.isNull, area.width >= 4, area.height >= 4 else { return nil }
            guard area.contains(pointer) else { return area }
            let fitted = fit(box, in: area)
            return fitted.width < minimumRegion.width || fitted.height < minimumRegion.height ? area : fitted
        }
        return display.map { fit(box, in: $0) }
    }

    /// `box` moved (and if need be shrunk) to lie inside `area`.
    static func fit(_ box: CGRect, in area: CGRect) -> CGRect {
        let width = min(box.width, area.width), height = min(box.height, area.height)
        let x = min(max(box.midX - width / 2, area.minX), area.maxX - width)
        let y = min(max(box.midY - height / 2, area.minY), area.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// One redacted picture for a pointer or window lesson. Every refusal is a sentence the reply can say.
    @MainActor static func look(_ source: CookieLessonSource, environment: CookieLessonEnvironment) async -> CookieLessonLook? {
        guard source == .pointer || source == .window else { return nil }
        guard environment.screenAllowed() else { return .refused("Screen access is off") }
        guard let target = environment.frontApp() else { return .refused("There's no app in front to look at") }
        if let reason = environment.refusal(target) { return .refused(reason) }
        let window = await environment.windowFrame(target.pid)
        let pointer = environment.pointer()
        let display = environment.displayFrame(window ?? CGRect(origin: pointer, size: .zero))
        let rect: CGRect? = source == .pointer
            ? region(pointer: pointer, window: window, display: display)
            : window.flatMap { window in
                let area = display.map { window.intersection($0) } ?? window
                return area.isNull || area.width < 4 || area.height < 4 ? nil : area
            }
        guard let rect else { return .refused("Couldn't find \(target.app)'s window to look at") }
        let captured = await withDeadline(seconds: captureSeconds) { () async -> Result<CompanionScreenCaptureUtility.RedactedJPEG?, Error> in
            do { return .success(try await environment.capture(rect)) } catch { return .failure(error) }
        }
        switch captured {
        case .success(let picture?)?: return .picture(data: picture.data, hidden: picture.hiddenItems, app: target.app, region: rect)
        case .success(nil)?: return .refused("Couldn't take a picture of that part of the screen")
        case .failure(let error as Redactor.Unchecked)?: return .refused(error.localizedDescription)
        case .failure(let error)?: return .refused("Couldn't take a picture of the screen (\(error.localizedDescription))")
        case nil: return .refused("Taking a picture of your screen took too long")
        }
    }

    /// The picture's caption: what it is, and that its words are data.
    static func caption(_ source: CookieLessonSource, app: String) -> String {
        "UNTRUSTED screen content — " + (source == .pointer
            ? "the part of \(app) around the user's pointer, what they want explained as a model"
            : "the user's \(app) window, what they want explained as a model")
    }

    // MARK: The planner

    /// What the model is told for a lesson from the screen. It stays inside the SCENE and CARD shapes
    /// `CookieScene` and `CookieCard` accept: any other field and the visual is dropped.
    static func instruction(_ source: CookieLessonSource, pictured: Bool) -> String {
        let from: String = switch source {
        case .circle: "the area they circled"
        case .pointer: "the part of their window around the pointer"
        case .window: "their front window"
        case .selection: "the text they selected"
        }
        let grounding = pictured || source == .selection
            ? "Grounding: copy every part, node, step, row and column label from words visible in \(source == .selection ? "the selected text" : "the picture") (names, headings, code, figures), exactly as written, shortened only by dropping words. If it doesn't name something you need, that label is general knowledge: say \"from general knowledge\" once as you name it, and end the title with \" · general knowledge\". Never invent a figure: every number must appear in it."
            : "You couldn't look this time, so every label is general knowledge: end the title with \" · general knowledge\" and say so once."
        return """
        LESSON FROM THE SCREEN. The user wants \(from) explained as a visual they can explore. This overrides the usual rule against visuals for things on the screen: build exactly one, as early in the reply as it can go, then explain it.
        Choose one:
        - SCENE for a physical or spatial thing: an engine, a molecule, a device, a building, anatomy, a network topology. Simple shapes placed where the real pieces sit; cut the outer casing so inner parts show, explode when parts hide each other.
        - CARD for an abstract thing: an error or a bug as a flow of its cause (what called what, what failed, what was raised), a procedure as steps, a balance sheet or a choice as compare (or number for the one figure that matters), dated events as a timeline.
        \(grounding)
        Exactly these fields, nothing else, every limit above (labels up to twenty-eight characters, a scene's numbers within ten, up to 24 parts):
        [SCENE {"title":"...","parts":[{"id":"a","label":"...","shape":"box","size":[1,1,1],"position":[0,0,0],"rotation":[0,0,0],"color":"steel","cut":true}],"explode":true,"spin":false}]
        [CARD {"kind":"flow","title":"...","nodes":[{"id":"a","label":"...","icon":"cube"}],"edges":[{"from":"a","to":"b","label":"..."}]}] or steps {"kind":"steps","title":"...","steps":[{"text":"..."}]}, compare {"kind":"compare","title":"...","columns":[{"heading":"...","points":["..."]}]}, timeline {"kind":"timeline","title":"...","events":[{"label":"...","when":"..."}]}, list {"kind":"list","title":"...","items":["..."]}, number {"kind":"number","value":"...","label":"...","caption":"..."}.
        Name the labelled parts or nodes in order in the sentence after the tag. Leave spin off; the user can say "spin it", "rotate left", "turn it around" or "label everything". End with up to two [NEXT:…] such as [NEXT:what does the impeller do?].
        Example, a pump diagram labelled Inlet, Impeller, Volute and Outlet: "here it is as a model [SCENE {"title":"Centrifugal pump","parts":[{"id":"inlet","label":"Inlet","shape":"cylinder","size":[0.14,0.6],"position":[0,0,0.5],"rotation":[90,0,0],"color":"sky"},{"id":"impeller","label":"Impeller","shape":"cylinder","size":[0.38,0.08],"position":[0,0,0],"rotation":[90,0,0],"color":"amber"},{"id":"volute","label":"Volute","shape":"cylinder","size":[0.6,0.3],"position":[0,0,0],"rotation":[90,0,0],"color":"steel","cut":true},{"id":"outlet","label":"Outlet","shape":"cylinder","size":[0.12,0.5],"position":[0.55,0.45,0],"color":"sky"}],"explode":true}] water comes in at the inlet, the impeller flings it outward, the volute gathers it, and it leaves through the outlet."
        Example, a Python traceback ending in KeyError: 'email': "here's how that error happened [CARD {"kind":"flow","title":"Why load_user raised KeyError","nodes":[{"id":"main","label":"main()"},{"id":"load","label":"load_user(row)"},{"id":"read","label":"row['email']"},{"id":"error","label":"KeyError: 'email'"}],"edges":[{"from":"main","to":"load","label":"calls"},{"from":"load","to":"read","label":"reads"},{"from":"read","to":"error","label":"raises"}]}] main() calls load_user(row), which reads row['email'], and because that row has no email key Python raises KeyError: 'email'."
        """
    }

    /// The honest card's words when a lesson ended with nothing to show.
    static func fallbackReason(_ tags: [CookieReplyTag]) -> String {
        tags.contains { $0.kind == "SCENE" || $0.kind == "CARD" }
            ? "The model Cookie was given didn't pass its checks (a shape, size or field it can't draw), so nothing was drawn."
            : "This answer came back as words only, with no model to show."
    }
}

// MARK: - Spoken commands for the model on screen

/// "Rotate left", "spin faster", "label everything" — said on their own, with a model up, they go
/// straight to it. Anything more ("rotate the PDF", "rotate it and tell me about the fan") is the
/// model's to read.
enum CookieLessonVoice {
    private static let leading = ["hey cookie ", "cookie ", "please ", "can you ", "could you ", "would you ", "now ", "ok ", "okay ", "and ", "then ", "just "]
    private static let trailing = [" please", " for me", " now", " a bit", " a little", " a little bit", " slightly", " more", " again"]
    private static let object = "(?: (?:it|this|that|the model|the scene|the thing|the object|the whole thing))?"

    static func command(_ text: String) -> CookieVisualCommand? {
        var words = CookieLessonFromScreen.normalised(text.replacingOccurrences(of: "’", with: "'"))
        var trimmed = true
        while trimmed {
            trimmed = false
            for prefix in leading where words.hasPrefix(prefix) { words.removeFirst(prefix.count); trimmed = true }
            for suffix in trailing where words.hasSuffix(suffix) { words.removeLast(suffix.count); trimmed = true }
        }
        func matches(_ pattern: String) -> [String]? {
            guard let expression = try? NSRegularExpression(pattern: "^" + pattern + "$"),
                  let match = expression.firstMatch(in: words, range: NSRange(location: 0, length: words.utf16.count)) else { return nil }
            return (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: words).map { String(words[$0]) } ?? ""
            }
        }
        if let found = matches("(?:rotate|turn|spin)" + object + " (?:to the |towards the )?(left|right)") {
            return .rotate(degrees: found[1] == "left" ? -CookieVisualCommand.rotateStep : CookieVisualCommand.rotateStep)
        }
        if let found = matches("(?:rotate|turn)" + object + " (?:by )?(\\d{1,3}) degrees?(?: (?:to the )?(left|right))?"),
           let degrees = Float(found[1]), degrees > 0, degrees <= 360 {
            return .rotate(degrees: found[2] == "left" ? -degrees : degrees)
        }
        if matches("(?:turn|rotate|spin|flip)" + object + " around|show me the back(?: of it)?|turn around") != nil {
            return .rotate(degrees: 180)
        }
        if matches("(?:spin|rotate)" + object + " faster|faster|speed it up|make it spin faster") != nil { return .spin(.faster) }
        if matches("(?:spin|rotate)" + object + " slower|slower|slow it down|make it spin slower") != nil { return .spin(.slower) }
        if matches("stop (?:it )?(?:spinning|rotating|turning)|stop the spin(?:ning)?|hold (?:it )?still|don't spin") != nil { return .spin(.stop) }
        if matches("spin" + object + "|start spinning|make it spin|keep spinning") != nil { return .spin(.start) }
        if matches("label (?:everything|all(?: the| of the)? parts|all|the parts|it all|every part)|show (?:all )?(?:the )?labels|labels on") != nil {
            return .labels(shown: true)
        }
        if matches("hide (?:all )?(?:the )?labels|(?:remove|turn off) (?:all )?(?:the )?labels|no labels|labels off") != nil {
            return .labels(shown: false)
        }
        return nil
    }

    /// What Cookie says it did, true to what the model can do.
    static func note(_ command: CookieVisualCommand, rateBefore: Float, rateAfter: Float, spinning: Bool,
                     reduceMotion: Bool, labelled: Int) -> String {
        switch command {
        case .rotate(let degrees):
            if abs(degrees) == 180 { return "Turned the model around." }
            let side = degrees < 0 ? "left" : "right"
            return abs(degrees) == CookieVisualCommand.rotateStep ? "Turned the model \(side)." : "Turned the model \(Int(abs(degrees).rounded()))° \(side)."
        case .spin(let change):
            if change == .stop { return "Stopped spinning." }
            if reduceMotion || !spinning { return "Reduce Motion is on, so the model stays still. Say “rotate left” or “rotate right” to turn it." }
            switch change {
            case .faster: return rateAfter == rateBefore ? "That's as fast as it spins." : "Spinning faster."
            case .slower: return rateAfter == rateBefore ? "That's as slow as it spins." : "Spinning slower."
            default: return "Spinning. Say “stop spinning” to hold it still."
            }
        case .labels(let shown):
            if !shown { return "Labels hidden. Say “label everything” to bring them back." }
            return labelled == 0 ? "This model has no labelled parts to show." : "Showing all \(labelled) \(labelled == 1 ? "label" : "labels")."
        default:
            return "Done."
        }
    }
}

extension CookieScenePresenter {
    /// A spoken command for the model on screen, applied now; what to tell the person, or nil when no
    /// model is up.
    func perform(spoken command: CookieVisualCommand) -> String? {
        guard let stage else { return nil }
        let before = stage.spinRate
        apply(command)
        return CookieLessonVoice.note(command, rateBefore: before, rateAfter: stage.spinRate, spinning: stage.spinning,
                                      reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                                      labelled: stage.scene.labelled.count)
    }
}

// MARK: - "Building your model…" and the honest fallback

/// The card that holds a lesson's place while the model works, and says plainly when nothing could be
/// drawn. It sits where the model will appear, takes clicks only over itself, and Esc (anywhere, it's
/// Cookie's own moment) closes it, stopping the lesson while it is still being built.
@MainActor
final class CookieLessonStatus: ObservableObject {
    enum Phase: Equatable {
        case looking
        case building
        case failed(String)
    }

    @Published private(set) var phase: Phase?
    @Published private(set) var subtitle = ""
    /// Esc or the close control while the model is being built: the person wants it stopped.
    var onCancel: () -> Void = {}
    /// Off in checks: the phases change without a window.
    var presents = true

    static let failureSeconds: Double = 12
    /// A lesson that never resolves (a voice that never reaches its tag) doesn't leave this up for good.
    static let buildingSeconds: Double = 120

    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var hideTask: Task<Void, Never>?

    static func subtitle(_ source: CookieLessonSource, app: String?) -> String {
        switch source {
        case .circle: return "From the area you circled"
        case .pointer: return app.map { "From what you're pointing at in \($0)" } ?? "From what you're pointing at"
        case .window: return app.map { "From your \($0) window" } ?? "From the window in front"
        case .selection: return "From the text you selected"
        }
    }

    func begin(_ source: CookieLessonSource) {
        subtitle = Self.subtitle(source, app: nil)
        set(source == .pointer || source == .window ? .looking : .building, hideAfter: Self.buildingSeconds)
    }

    /// The look is done (or skipped): the model is working now.
    func building(_ source: CookieLessonSource, app: String?) {
        guard phase != nil else { return }
        subtitle = Self.subtitle(source, app: app)
        set(.building, hideAfter: Self.buildingSeconds)
    }

    func fail(_ reason: String) {
        set(.failed(reason), hideAfter: Self.failureSeconds)
    }

    func dismiss() {
        hideTask?.cancel()
        hideTask = nil
        phase = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.close()
        })
    }

    /// Esc or close: stops a lesson still being built; a failure card just goes.
    func close() {
        let building = phase == .looking || phase == .building
        dismiss()
        if building { onCancel() }
    }

    private func set(_ phase: Phase, hideAfter seconds: Double) {
        self.phase = phase
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
        guard presents else { return }
        let announcement: String = switch phase {
        case .looking: "Looking at what you're pointing at"
        case .building: "Building your model"
        case .failed(let reason): "Couldn't build this model. " + reason
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: announcement, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        if panel == nil { show() } else { resize() }
    }

    private func show() {
        let hosting = CookieLessonStatusHostingView(rootView: CookieLessonStatusView(status: self))
        let newPanel = CookieCardPanel(contentRect: CookieCardPresenter.frame(for: hosting.fittingSize, near: nil))
        newPanel.contentView = hosting
        newPanel.alphaValue = 0
        newPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            newPanel.animator().alphaValue = 1
        }
        panel = newPanel
        installMonitors()
    }

    /// The failure card is taller than the building one; it grows downward from the same top edge.
    private func resize() {
        guard let panel, let content = panel.contentView else { return }
        let size = content.fittingSize
        panel.setFrame(CGRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let follow: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let panel = self?.panel else { return }
                panel.ignoresMouseEvents = !panel.frame.insetBy(dx: CookieCardView.shadowMargin, dy: CookieCardView.shadowMargin).contains(NSEvent.mouseLocation)
            }
        }
        if let moved = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: follow) { monitors.append(moved) }
        if let moved = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { follow($0); return $0 }) { monitors.append(moved) }
        let escape: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return }
            MainActor.assumeIsolated { self?.close() }
        }
        if let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: escape) { monitors.append(keys) }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { escape($0); return $0 }) { monitors.append(keys) }
    }
}

struct CookieLessonStatusView: View {
    @ObservedObject var status: CookieLessonStatus
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var paper: Color { CookieCardView.paper(colorScheme) }
    private var inkText: Color { CookieCardView.inkText(colorScheme) }
    private var failed: String? { if case .failed(let reason) = status.phase { return reason } else { return nil } }

    private var title: String {
        switch status.phase {
        case .looking: return "Looking at what you're pointing at…"
        case .failed: return "Couldn't build this model"
        default: return "Building your model…"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: failed == nil ? "cube.transparent" : "exclamationmark.triangle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(CookieMarksLayer.ink)
                .symbolEffect(.pulse, options: .repeating, isActive: failed == nil && !reduceMotion)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(inkText)
                Text(failed ?? status.subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(inkText.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                if failed != nil {
                    Text("The explanation is in Cookie's reply. Ask again, or circle the part you mean.")
                        .font(.system(size: 11))
                        .foregroundStyle(inkText.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.trailing, 22)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 300, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(paper)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(inkText.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.16), radius: 14, y: 6)
        )
        .overlay(alignment: .topTrailing) {
            Button { status.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(inkText.opacity(0.58))
                    .frame(width: CookieCardView.closeSize, height: CookieCardView.closeSize)
                    .background(Circle().fill(inkText.opacity(0.06)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel(failed == nil ? "Stop building the model" : "Close")
            .padding(CookieCardView.closeInset)
        }
        .padding(CookieCardView.shadowMargin)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title + ". " + (failed ?? status.subtitle))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: status.phase)
    }
}

/// The close control answers the first click even though Cookie isn't the active app.
private final class CookieLessonStatusHostingView: NSHostingView<CookieLessonStatusView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
