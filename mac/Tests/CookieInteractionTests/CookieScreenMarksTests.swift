//
//  CookieScreenMarksTests.swift
//  Pointing at real controls: numbered tags on the model's screenshot, and POINT:#id.
//

import AppKit
import ApplicationServices
import ImageIO

@MainActor
enum CookieScreenMarksTests {
    static func run() async {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }

        // A reply's POINT tags, as they come out of the words: by tag, by tag with a label and
        // a screen, a screen alone, and the pixel forms unchanged.
        let reply = "open the share menu [POINT:#12:Share] then [POINT:#40:Send:screen2], or [POINT:#7:screen2] and [POINT:880,24:Save] [POINT:none]"
        let (spoken, tags) = CookieReplyTags.split(reply)
        check(!spoken.contains("[POINT") && spoken.hasPrefix("open the share menu then"), "tags leave the spoken words: \(spoken)")
        let points = tags.filter { $0.kind == "POINT" }.map(CompanionManager.parsePointing)
        check(points.count == 5, "every POINT tag parsed")
        check(points[0].elementID == 12 && points[0].elementLabel == "Share" && points[0].coordinate == nil && points[0].screenNumber == nil, "#12:Share")
        check(points[0].offset == "open the share menu ".utf16.count, "a tag point keeps its place on the speech clock")
        check(points[1].elementID == 40 && points[1].elementLabel == "Send" && points[1].screenNumber == 2, "#40:Send:screen2")
        check(points[2].elementID == 7 && points[2].elementLabel == nil && points[2].screenNumber == 2, "#7:screen2 is a screen, not a label")
        check(points[3].elementID == nil && points[3].coordinate == CGPoint(x: 880, y: 24) && points[3].elementLabel == "Save", "pixels still work")
        check(points[4].coordinate == nil && points[4].elementID == nil && points[4].elementLabel == "none", "none")
        check(CompanionManager.parsePointing(CookieReplyTag(kind: "POINT", body: "#x:Save", offset: 0)).elementID == nil, "a bad id is no target")

        // Layout: each tag sits beside its own control (never on it), inside the picture, never on
        // another tag; the smallest control is placed first; the same box twice is tagged once.
        let size = CGSize(width: 1372, height: 891)
        let row = (0..<8).map { (id: $0 + 1, rect: CGRect(x: 200 + CGFloat($0) * 40, y: 100, width: 32, height: 22)) }
        let twin = (id: 9, rect: CGRect(x: 201, y: 100, width: 32, height: 22))
        let field = (id: 10, rect: CGRect(x: 200, y: 400, width: 600, height: 200))
        let corner = (id: 11, rect: CGRect(x: 0, y: 0, width: 30, height: 20))
        let laid = CookieScreenMarks.layout(row + [twin, field, corner], in: size)
        let bounds = CGRect(origin: .zero, size: size)
        check(!laid.contains { $0.id == 9 } || !laid.contains { $0.id == 1 }, "one box, one tag")
        check(laid.contains { $0.id == 10 } && laid.contains { $0.id == 11 }, "a big field and a corner button get tags")
        for tag in laid {
            check(bounds.contains(tag.tag), "tag \(tag.id) inside the image")
            check(!tag.tag.insetBy(dx: 0.5, dy: 0.5).intersects(tag.control), "tag \(tag.id) doesn't cover its own control")
        }
        for (index, a) in laid.enumerated() {
            for b in laid.dropFirst(index + 1) { check(!a.tag.intersects(b.tag), "tags \(a.id) and \(b.id) don't collide") }
        }
        check(laid.map(\.id) == laid.map(\.id).sorted(), "tags come back in id order")
        check(CookieScreenMarks.tagHeight(for: size) >= 12, "legible tags")
        // Crowded: never more than the limit.
        let grid = (0..<600).map { (id: $0 + 1, rect: CGRect(x: CGFloat($0 % 30) * 45 + 5, y: CGFloat($0 / 30) * 44 + 20, width: 30, height: 20)) }
        let crowded = CookieScreenMarks.layout(grid, in: size)
        check(crowded.count <= CookieScreenMarks.maxTags && crowded.count > 20, "at most ~120 tags: \(crowded.count)")
        check(CookieScreenMarks.layout(grid, in: size, limit: 5).count == 5, "the limit holds")

        // Placing: only actionable controls on screen and in the window, mapped to each screenshot's
        // pixels; the second display's control lands on the second picture.
        let mainHeight: CGFloat = 900
        let screens = [CookieScreenMarks.Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), width: 1372, height: 857),
                       CookieScreenMarks.Screen(frame: CGRect(x: 1440, y: 0, width: 1440, height: 900), width: 1372, height: 857)]
        let controls = [
            CookieScreenMarks.Control(id: 1, role: "AXButton", label: "Save", frame: CGRect(x: 720, y: 450, width: 60, height: 24)),
            CookieScreenMarks.Control(id: 2, role: "AXStaticText", label: "Title", frame: CGRect(x: 100, y: 100, width: 80, height: 20)),
            CookieScreenMarks.Control(id: 3, role: "AXButton", label: "Scrolled away", frame: CGRect(x: 100, y: 5000, width: 60, height: 24)),
            CookieScreenMarks.Control(id: 4, role: "AXTextField", label: "", frame: CGRect(x: 2000, y: 300, width: 200, height: 24)),
            CookieScreenMarks.Control(id: 5, role: "AXButton", label: "No frame", frame: nil),
        ]
        let window = CGRect(x: 0, y: 0, width: 2880, height: 900)
        let placed = CookieScreenMarks.place(controls, window: window, screens: screens, mainHeight: mainHeight)
        check(placed.count == 2 && placed[0].map(\.id) == [1] && placed[1].map(\.id) == [4], "actionable, visible controls only: \(placed.map { $0.map(\.id) })")
        let save = placed[0][0].control
        let scale = 1372.0 / 1440.0
        check(abs(save.minX - 720 * scale) < 0.5 && abs(save.minY - 450 * (857.0 / 900.0)) < 0.5, "CG frame to screenshot pixels: \(save)")
        check(abs(placed[1][0].control.minX - (2000 - 1440) * scale) < 0.5, "second display's own pixels")

        // The list that goes with the pictures: ids, roles, labels as data, secrets hidden.
        let secret = CookieScreenMarks.Control(id: 6, role: "AXButton", label: "Pay 4242 4242 4242 4242 \"now\"", frame: nil)
        let list = CookieScreenMarks.list([[CookieScreenMarks.Tag(id: 1, control: .zero, tag: .zero), CookieScreenMarks.Tag(id: 6, control: .zero, tag: .zero)],
                                           [CookieScreenMarks.Tag(id: 4, control: .zero, tag: .zero)]],
                                          controls: controls + [secret], screens: 2)
        check(list.hasPrefix("UNTRUSTED controls"), "the list is marked as screen content")
        check(list.contains("[1] Button \"Save\" (screen 1)") && list.contains("[4] TextField (screen 2)"), list)
        check(!list.contains("4242") && list.contains("[hidden]") && list.contains("'now'"), "secrets hidden, quotes kept tidy: \(list)")
        check(CookieScreenMarks.list([[]], controls: controls, screens: 1).isEmpty, "no tags, no list")

        // The tags are drawn into a copy for the model; the original picture is untouched.
        let picture = jpeg(width: 400, height: 300, gray: 0.92)
        let tag = CookieScreenMarks.Tag(id: 7, control: CGRect(x: 100, y: 120, width: 60, height: 24), tag: CGRect(x: 100, y: 100, width: 20, height: 16))
        let drawn = CookieScreenMarks.draw([tag], on: picture)
        check(drawn != nil && drawn != picture, "a tagged copy")
        if let drawn, let image = decode(drawn), let original = decode(picture) {
            check(image.width == 400 && image.height == 300, "same pixels as sent, so coordinates still match")
            let inside = rgb(image, x: 103, y: 104), away = rgb(image, x: 300, y: 250), before = rgb(original, x: 103, y: 104)
            check(inside.r > 0.8 && inside.b < 0.45 && before.b > 0.8, "amber tag where it was placed: \(inside)")
            check(abs(away.r - 0.92) < 0.06 && abs(away.b - 0.92) < 0.06, "the rest of the picture unchanged: \(away)")
        }
        check(CookieScreenMarks.draw([tag], on: Data("not a picture".utf8)) == nil, "an unreadable picture isn't tagged")

        // End to end: a read becomes the turn's latest look, the model's copy is tagged, the capture
        // Cookie keeps is not, the look is recorded to Proof, and POINT:#id finds that control.
        if let main = NSScreen.screens.first?.frame {
            let element = AXUIElementCreateApplication(getpid())
            let found = [
                MacOperator.Observed(element: element, role: "AXStaticText", label: "Heading", frame: CGRect(x: main.minX + 40, y: 40, width: 100, height: 20), line: ""),
                MacOperator.Observed(element: element, role: "AXButton", label: "Share", frame: CGRect(x: main.minX + 300, y: 200, width: 70, height: 24), line: ""),
            ]
            let read = CookieScreenMarks.Read(app: 4242, appName: "Notes", found: found, window: nil)
            let capture = CompanionScreenCapture(imageData: jpeg(width: 1372, height: Int(1372 * main.height / main.width), gray: 0.9),
                label: "user's screen (cursor is here)", isCursorScreen: true,
                displayWidthInPoints: Int(main.width), displayHeightInPoints: Int(main.height), displayFrame: main,
                screenshotWidthInPixels: 1372, screenshotHeightInPixels: Int(1372 * main.height / main.width), hiddenItems: 0)
            let proof = CookieProof(file: nil)
            let marked = await CookieScreenMarks.mark(read, captures: [capture], proof: proof)
            check(marked?.count == 1 && marked?.images[0] != nil && marked?.images[0] != capture.imageData, "the model's copy is tagged")
            check(marked?.list.contains("[2] Button \"Share\"") == true && marked?.list.contains("Heading") == false, "only the button is listed")
            check(proof.entries.first?.kind == .saw && proof.entries.first?.app == "Notes"
                  && proof.entries.first?.summary.contains("Share") == false, "the read is in Proof, without the words")
            let tagged = CompanionManager.parsePointing(CookieReplyTags.split("tap share [POINT:#2:Share]").tags[0])
            check(tagged.elementID.flatMap { MacOperator.shared.observedElement($0) }?.label == "Share", "POINT:#2 resolves to the tagged control")
            check(MacOperator.shared.observedElement(3) == nil, "an id the look didn't have falls back to the label")
            // A `look` mid-turn renumbers the controls: #2 is now the heading, so the tag's "Share" is found by its words.
            MacOperator.shared.adoptLook([found[1], found[0]], app: 4242)
            let renumbered = MacOperator.shared.observedElement(2)
            check(renumbered?.label == "Heading" && !CompanionManager.tagNames(observed: renumbered!.label, tagged: tagged.elementLabel),
                  "a tag whose words aren't the control now under its id doesn't point at that control")
            check(CompanionManager.tagNames(observed: "Share…", tagged: "Share") && CompanionManager.tagNames(observed: "Heading", tagged: nil)
                  && CompanionManager.tagNames(observed: "", tagged: "Share"), "the same words, or nothing to compare, keep the tagged control")
            let manager = (try? String(contentsOfFile: "Cookie/CompanionManager.swift", encoding: .utf8)) ?? ""
            check(manager.contains("observedElement(id), Self.tagNames(observed: observed.label, tagged: label)"),
                  "the reply's POINT takes the find-by-words path when the words differ")
            MacOperator.shared.endRun()
            check(MacOperator.shared.observedElement(2) == nil, "ids end with the run")
        }

        // Reading is bounded, and Cookie never reads its own windows.
        let started = Date()
        let own = await CookieScreenMarks.read(NSRunningApplication.current)
        check(own == nil && Date().timeIntervalSince(started) < CookieScreenMarks.readSeconds + 0.1, "no read of Cookie itself, quickly")

        // The voice prompt teaches the tag form first, pixels only without a tag.
        let prompt = CompanionManager.companionVoiceResponseSystemPrompt
        check(prompt.contains("[POINT:#12:label] whenever the thing carries a tag") && prompt.contains("only for something with no tag")
              && prompt.contains("[POINT:#7:Share]") && !prompt.contains("after you have used look"), "prompt prefers tags")
        check(CookieImageSize.screenLongEdge == CookieImageSize.maxEdge, "screenshots at the model's native edge when the budget allows")

        print("\(checks) screen marks checks passed.")
    }

    private static func jpeg(width: Int, height: Int, gray: CGFloat) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
    }

    private static func decode(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    /// One pixel, top-left origin, 0…1.
    private static func rgb(_ image: CGImage, x: Int, y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (CGFloat(pixel[0]) / 255, CGFloat(pixel[1]) / 255, CGFloat(pixel[2]) / 255)
    }
}
