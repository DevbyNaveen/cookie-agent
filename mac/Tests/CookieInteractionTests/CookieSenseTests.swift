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
        sense.stopForTesting()
        print("helper checks: \(passed) passed")
    }

    static func picture(lines: [String]) -> CGImage {
        let width = 1280, height = 800
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
        for (index, text) in lines.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font]))
            context.textPosition = CGPoint(x: 40, y: 700 - index * 60)
            CTLineDraw(line, context)
        }
        return context.makeImage()!
    }
}
