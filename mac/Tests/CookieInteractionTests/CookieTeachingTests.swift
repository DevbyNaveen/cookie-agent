import AppKit
import SwiftUI

@MainActor
enum CookieTeachingTests {
    static let photosynthesis = #"[CARD {"kind":"flow","title":"How a leaf makes sugar","nodes":[{"id":"sun","label":"Sunlight","icon":"sun.max"},{"id":"water","label":"Water","icon":"drop"},{"id":"carbon","label":"Carbon dioxide","icon":"cloud"},{"id":"leaf","label":"Leaf","icon":"leaf"},{"id":"sugar","label":"Sugar","icon":"cube"},{"id":"oxygen","label":"Oxygen","icon":"wind"}],"edges":[{"from":"sun","to":"leaf"},{"from":"water","to":"leaf"},{"from":"carbon","to":"leaf"},{"from":"leaf","to":"sugar"},{"from":"leaf","to":"oxygen"}]}]"#

    static func run() {
        let spoken = "The fantastic view is ready. The fan draws air in. Later, the compressor squeezes it."
        let offsets = CookieCard.namedBeats(["fan", "compressor"], from: 0, in: spoken)
        precondition(offsets == [0, (spoken as NSString).range(of: "fan draws").location,
                                 (spoken as NSString).range(of: "compressor").location])
        let followup = CookieReplyTags.split("Look at [TEACH:leaf] the leaf.")
        precondition(followup.spoken == "Look at  the leaf." || followup.spoken == "Look at the leaf.")
        precondition(followup.tags.count == 1 && followup.tags[0].kind == "TEACH")
        let tags = CookieReplyTags.split(photosynthesis).tags
        let card = CookieCard(tag: tags[0])!
        guard case .flow(_, let nodes, let edges, _, _) = card.content else { preconditionFailure("diagram must be a graph") }
        precondition(nodes.count == 6 && edges.count == 5 && nodes.allSatisfy { $0.icon != nil })
        let bad = photosynthesis.replacingOccurrences(of: "sun.max", with: "unknown.symbol")
        precondition(CookieCard(tag: CookieReplyTags.split(bad).tags[0]) == nil)
        let narration = "Sunlight reaches the plant. Water arrives next. Carbon dioxide enters the Leaf, which makes Sugar and Oxygen."
        let beats = card.revealOffsets(in: narration, nextCardOffset: nil)
        precondition(beats.count == card.elements.count && beats == beats.sorted())
        for (i, element) in card.elements.enumerated() {
            if case .node(let id) = element, let node = nodes.first(where: { $0.id == id }) {
                precondition(beats[i] == (narration as NSString).range(of: node.label).location)
            }
        }
        for count in 1...6 {
            let boxes = (0..<count).map { index in
                let point = CookieSceneLabelLayout.centre(index: index, count: count, size: CGSize(width: 520, height: 360))
                return CGRect(x: point.x - 73, y: point.y - 14, width: 146, height: 28)
            }
            for i in boxes.indices {
                precondition(CGRect(x: 0, y: 0, width: 520, height: 360).contains(boxes[i]))
                for j in boxes.indices where j > i { precondition(!boxes[i].intersects(boxes[j])) }
            }
        }
        let desktop = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let rightPane = CGRect(x: -720, y: 0, width: 720, height: 900)
        let placed = CookieCardPresenter.teachingFrame(size: CGSize(width: 560, height: 500), visible: desktop, avoiding: [rightPane])
        precondition(desktop.contains(placed) && !placed.intersects(rightPane), "avoid the active right pane on a negative-origin display")
        let leftPane = CGRect(x: -1440, y: 0, width: 720, height: 900)
        let alternate = CookieCardPresenter.teachingFrame(size: CGSize(width: 560, height: 500), visible: desktop, avoiding: [leftPane])
        precondition(desktop.contains(alternate) && !alternate.intersects(leftPane), "placement must adapt when the left pane is active")
        let a = UUID(), b = UUID()
        CookieHand.shared.teach(owner: a, at: CGPoint(x: 10, y: 20))
        CookieHand.shared.teach(owner: b, at: CGPoint(x: 30, y: 40))
        CookieHand.shared.stopTeaching(owner: a)
        precondition(CookieHand.shared.teaching?.owner == b, "old panel cannot withdraw a new lesson's pointer")
        CookieHand.shared.stopTeaching(owner: b)
        precondition(CookieHand.shared.teaching == nil)
        let reveal = CookieCardReveal(card: card)
        reveal.anchors = ["leaf": CGPoint(x: 100, y: 200)]
        var focused: CGPoint?
        reveal.onFocus = { focused = $0 }
        reveal.collapsed = true
        reveal.focus("leaf")
        precondition(!reveal.collapsed, "follow-up targeting expands the retained visual")
        precondition(focused == CGPoint(x: 100, y: 200) && reveal.activeNode == "leaf")
        reveal.pauseTeaching()
        precondition(reveal.activeNode == nil && reveal.selectedNode == "leaf" && reveal.shown > 0, "interruption keeps the picture")
        reveal.reveal(through: card.elements.count - 1, instant: true)
        if CommandLine.arguments.contains("--render-teaching") {
            let renderer = ImageRenderer(content: CookieCardView(reveal: reveal, onClose: {}).environment(\.colorScheme, .light))
            renderer.scale = 2
            guard let image = renderer.cgImage else { preconditionFailure("teaching diagram did not render") }
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            try! data.write(to: URL(fileURLWithPath: "/tmp/cookie-teaching-paper.png"))
        }
        if CommandLine.arguments.contains("--preview-teaching") {
            let json = #"[SCENE {"title":"Inside a jet engine","parts":[{"id":"case","shape":"cylinder","size":[0.55,2.3],"position":[0,0,0],"rotation":[0,0,90],"color":"steel","cut":true},{"id":"fan","label":"Fan","shape":"cylinder","size":[0.5,0.08],"position":[-1,0,0],"rotation":[0,0,90],"color":"sky"},{"id":"compressor","label":"Compressor","shape":"cone","size":[0.42,0.6],"position":[-0.55,0,0],"rotation":[0,0,-90],"color":"mint"},{"id":"combustor","label":"Combustor","shape":"cylinder","size":[0.3,0.5],"position":[0,0,0],"rotation":[0,0,90],"color":"amber"},{"id":"turbine","label":"Turbine","shape":"cylinder","size":[0.34,0.3],"position":[0.45,0,0],"rotation":[0,0,90],"color":"rose"},{"id":"nozzle","label":"Nozzle","shape":"cone","size":[0.3,0.45],"position":[0.85,0,0],"rotation":[0,0,-90],"color":"graphite"}],"spin":false}]"#
            let scene = CookieScene(tag: CookieReplyTags.split(json).tags[0])!
            let presenter = CookieScenePresenter()
            presenter.showNow(scene, near: nil)
            _ = presenter.focus("compressor")
            print("TEACHING_PREVIEW_WINDOW \(presenter.previewWindowNumber ?? 0)")
            fflush(stdout)
            let until = Date().addingTimeInterval(35)
            while Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            precondition(CookieHand.shared.teaching.map { presenter.previewFrame?.contains($0.point) == true } == true,
                         "3D focus must project inside its real window")
            presenter.pauseTeaching()
            precondition(presenter.teachingContext?.contains("Selected: compressor") == true)
            presenter.dismiss()
        }
        // A lesson folds when left alone and closes much later; it never stays open over the work forever.
        precondition(CookieLessonIdle.step(idle: 10, collapsed: false) == .stay)
        precondition(CookieLessonIdle.step(idle: CookieLessonIdle.collapseAfter, collapsed: false) == .collapse)
        precondition(CookieLessonIdle.step(idle: CookieLessonIdle.collapseAfter, collapsed: true) == .stay)
        precondition(CookieLessonIdle.step(idle: CookieLessonIdle.closeAfter, collapsed: true) == .close)
        // The hand goes to a node while Cookie explains it, never to one the person clicked, and
        // lets go when the explanation ends.
        let tapped = CookieCardReveal(card: card)
        var handMoves = 0
        tapped.onFocus = { _ in handMoves += 1 }
        tapped.anchors = ["sun": CGPoint(x: 10, y: 10), "water": CGPoint(x: 20, y: 20)]
        tapped.focus("sun", hand: false)
        precondition(handMoves == 0 && tapped.activeNode == "sun", "a clicked node is highlighted, not pointed at")
        tapped.focus("water")
        precondition(handMoves > 0, "a node Cookie names is pointed at")
        let explained = handMoves
        tapped.pauseTeaching()
        tapped.pointAtActiveNode()
        precondition(handMoves == explained && tapped.activeNode == nil)
        print("7 teaching checks passed.")
    }
}
