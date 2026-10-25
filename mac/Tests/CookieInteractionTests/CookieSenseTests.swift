import AppKit
import CoreText

/// The real cookie-sense helper, when it has been built (mac/cookie-sense): pictures go in as raw
/// pixels, reads come back as `CookieScreenRead`, and a helper that stops is started again.
enum CookieSenseTests {
    static func run() async {
        let built = URL(fileURLWithPath: "cookie-sense/.build/release/cookie-sense")
        guard FileManager.default.isExecutableFile(atPath: built.path) else {
            print("helper checks: 0 passed (cookie-sense isn't built)")
            return
        }
        let sense = CookieSense(helperURL: built)
        var passed = 0

        // Text on a screen: lines with word boxes, every check answered, the test card covered.
        let page = picture(lines: ["Card 4242 4242 4242 4242 expires soon", "Save", "Search mail",
                                   "The quick brown fox jumps over the lazy dog"])
        let read = try! await sense.read(page, faces: true)
        precondition(read.lines.count >= 3 && read.textChecked && read.faces != nil, "\(read.textRuns) \(read.lines.map(\.text))")
        precondition(read.lines.allSatisfy { !$0.words.isEmpty }, "every line has its word boxes")
        let found = try! Redactor.boxes(in: read, hideSecrets: true, blurFaces: true)
        precondition(found.text.count == 1, "the card, and only the card: \(found.text)")
        passed += 1

        // A blank screen: no lines, the detector agrees, and it is near uniform: it may go.
        let blank = picture(lines: [])
        var empty = try! await sense.read(blank, faces: false)
        precondition(empty.lines.isEmpty && empty.textRectangles == 0 && empty.textRuns == [0])
        empty.nearUniform = CookieVisionText.nearlyUniform(blank)
        precondition(empty.textChecked)
        passed += 1

        // The helper stops: the next read starts it again.
        sense.stopForTesting()
        try? await Task.sleep(for: .milliseconds(200))
        let again = try! await sense.read(page, faces: false)
        precondition(again.lines.count >= 3)
        passed += 1
        // The reported terminal walkthrough: resolve each quote, not the tab or entire panel.
        let phrases = ["No screen dimming", "A thin outline", "Instructions to use points and underlines"]
        let walkthrough = picture(lines: ["Fix cookie pointer bugs"] + phrases, fontName: "Menlo")
        let reading = try! await sense.read(walkthrough, faces: false)
        let capture = CompanionScreenCapture(imageData: Data(), label: "screen 1", isCursorScreen: true,
            displayWidthInPoints: 1280, displayHeightInPoints: 800, displayFrame: CGRect(x: 0, y: 0, width: 1280, height: 800),
            screenshotWidthInPixels: 1280, screenshotHeightInPixels: 800, hiddenItems: 0)
        var previousY = 700.0
        for phrase in phrases {
            let matches = CookieReadingPen.screenshotLines(Folded([phrase]).characters, in: reading.lines, capture: capture)
            precondition(matches.count == 1 && matches[0].count == 1, "one exact line for \(phrase): \(reading.lines.map(\.text))")
            let rect = matches[0][0].rect
            precondition(rect.midY < previousY && rect.height < 40 && rect.width < 800, "precise, ordered text bounds")
            previousY = rect.midY
        }
        passed += 1
        // Optional local replay; the screenshot stays on this Mac and is never a repository fixture.
        if let flag = CommandLine.arguments.firstIndex(of: "--reading-screenshot"), flag + 1 < CommandLine.arguments.count {
            let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
            let image = CookieVisionText.image(from: data)!
            let actual = try! await sense.read(image, faces: false)
            let snapshot = CompanionScreenCapture(imageData: data, label: "replay", isCursorScreen: true,
                displayWidthInPoints: image.width, displayHeightInPoints: image.height,
                displayFrame: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                screenshotWidthInPixels: image.width, screenshotHeightInPixels: image.height, hiddenItems: 0)
            for phrase in phrases {
                let matches = CookieReadingPen.screenshotLines(Folded([phrase]).characters, in: actual.lines, capture: snapshot)
                precondition(matches.count == 1 && matches[0].count == 1, "screenshot quote not uniquely resolved: \(phrase)")
                let rect = matches[0][0].rect
                precondition(rect.height < 50 && rect.width < Double(image.width) * 0.7)
                print("PASS screenshot reading bounds \(rect)")
            }
            passed += 1
        }
        sense.stopForTesting()
        print("helper checks: \(passed) passed")
    }

    static func picture(lines: [String], fontName: String = "Helvetica") -> CGImage {
        let width = 1280, height = 800
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName(fontName as CFString, 22, nil)
        for (index, text) in lines.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font]))
            context.textPosition = CGPoint(x: 40, y: 700 - index * 60)
            CTLineDraw(line, context)
        }
        return context.makeImage()!
    }
}
