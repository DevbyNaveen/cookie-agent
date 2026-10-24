//
//  CookieVisionText.swift
//  Cookie
//
//  The one place the app reads screenshots: text lines (with a box for every
//  word, so any part of a line can be placed) and faces — in the cookie-sense
//  helper (`CookieSense`) when the app has one, else in this process. Vision's accurate
//  model loads on first use: on an M4 that took 13–28 s in a fresh process
//  and sometimes failed outright (e5rt error 13), and in that process every
//  later accurate call failed too; warm, it reads a screen in ~0.15 s. So it
//  is warmed once at launch, off the main thread, and nothing waits on it:
//  until it is ready, and for good once it has failed or the warm-up ran past
//  40 s, text is read with .fast (0.04–0.45 s, fewer lines).
//
//  A read says how it went, not only what it found (`CookieScreenRead`), so
//  the redactor can tell "no text here" from "the reader saw nothing".
//

import CoreText
import Foundation
import ImageIO
import os
import Vision

/// One word of a recognised line: its UTF-16 range in the line and its box.
struct CookieTextWord: Codable, Equatable {
    let start: Int
    let end: Int
    /// Normalised to the image, bottom-left origin (Vision's convention).
    let box: CGRect
}

/// One recognised line of text and where each of its words is.
struct CookieTextLine: Codable, Equatable {
    let text: String
    /// The whole line, normalised, bottom-left origin.
    let box: CGRect
    let words: [CookieTextWord]

    /// The box around `range` of `text`: the union of the words it touches (at least as wide as
    /// the range, so a secret is always covered whole). Nil when the range touches no word.
    func boundingBox(for range: Range<String.Index>) -> CGRect? {
        let start = range.lowerBound.utf16Offset(in: text), end = range.upperBound.utf16Offset(in: text)
        let touched = words.filter { $0.start < end && $0.end > start }
        guard let first = touched.first else { return nil }
        return touched.dropFirst().reduce(first.box) { $0.union($1.box) }
    }

    /// Words of `text` as UTF-16 ranges: runs of non-whitespace.
    static func wordRanges(in text: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start: Int?
        var offset = 0
        for character in text {
            let length = character.utf16.count
            if character.isWhitespace {
                if let open = start { ranges.append(open..<offset) }
                start = nil
            } else if start == nil {
                start = offset
            }
            offset += length
        }
        if let open = start { ranges.append(open..<offset) }
        return ranges
    }
}

/// Everything one look at a picture found, and how each check went.
struct CookieScreenRead: Codable, Equatable {
    var lines: [CookieTextLine] = []
    /// Faces, normalised, bottom-left origin; nil when face detection was asked for and failed.
    var faces: [CGRect]? = []
    /// Each text recognition that ran, in order (accurate, then fast): its line count, nil on an error.
    var textRuns: [Int?] = []
    /// Text rectangles found by the separate text detector; nil when it failed or didn't run.
    var textRectangles: Int?
    /// The picture is close to one colour (few edges anywhere).
    var nearUniform = false

    /// Whether the text in it was checked well enough to send it. Lines found by a recognizer
    /// that ran are scanned for secrets, so they count. With no lines at all, that is believed
    /// only when every recognizer that ran did so without an error and either the separate text
    /// detector found no text either or the picture is near uniform: Vision has been seen to
    /// return no lines and no error from a model that never loaded (forums 824639), and a
    /// screen of text that "has no text" must not leave the Mac.
    var textChecked: Bool {
        guard !textRuns.isEmpty else { return false }
        if textRuns.contains(where: { ($0 ?? 0) > 0 }) { return true }
        guard !textRuns.contains(where: { $0 == nil }) else { return false }
        return textRectangles == 0 || nearUniform
    }
}

enum CookieVisionText {
    enum State { case warming, ready, unavailable }

    private static let current = OSAllocatedUnfairLock(initialState: State.warming)
    static var state: State { current.withLock { $0 } }

    /// Starts the reader: the cookie-sense helper when the app has one (it warms the accurate model
    /// in its own process), else the accurate model in this one. Called once, at launch. Not on an
    /// OS where accurate already failed to load (`CookieSense.accurateKnownBroken`): there a failed
    /// load costs ~26 s and slows every other read while it runs.
    static func warmUp() {
        if CookieSense.shared.isBundled {
            CookieSense.shared.start()
            return
        }
        guard !CookieSense.accurateKnownBroken else {
            current.withLock { $0 = .unavailable }
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let started = Date()
            do {
                guard let image = sample() else { throw CocoaError(.featureUnsupported) }
                let lines = try recognize(VNImageRequestHandler(cgImage: image, options: [:]), level: .accurate)
                // Ready means it read the sample, not merely that it didn't throw.
                guard !lines.isEmpty else { throw CocoaError(.featureUnsupported) }
                let ready = current.withLock { state -> Bool in
                    guard state == .warming else { return false }
                    state = .ready
                    return true
                }
                print(ready ? "👁️ Vision text: accurate ready after \(String(format: "%.1f", Date().timeIntervalSince(started))) s"
                            : "👁️ Vision text: accurate loaded after the 40 s limit, staying on fast")
            } catch {
                current.withLock { $0 = .unavailable }
                UserDefaults.standard.set(CookieSense.operatingSystem, forKey: CookieSense.accurateFailedOSKey)
                print("⚠️ Vision text: accurate unavailable, reading with fast: \(error)")
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 40) {
            let gaveUp = current.withLock { state -> Bool in
                guard state == .warming else { return false }
                state = .unavailable
                return true
            }
            if gaveUp { print("⚠️ Vision text: accurate still loading after 40 s, reading with fast") }
        }
    }

    /// Text (and faces, when asked) in a picture, for the redactor: accurate once warm, and fast
    /// as well whenever accurate failed or found nothing; the text detector and an edge count
    /// when no recognizer found a line. Throws only when the picture can't be read at all.
    ///
    /// With the cookie-sense helper, it reads (a failure is thrown, so the redactor refuses the
    /// picture); without it (a development build), this process does.
    static func read(_ image: CGImage, faces: Bool) async throws -> CookieScreenRead {
        guard CookieSense.shared.isBundled else {
            return try await Task.detached(priority: .userInitiated) { try readNow(image, faces: faces) }.value
        }
        var read = try await CookieSense.shared.read(image, faces: faces)
        if read.lines.isEmpty { read.nearUniform = nearlyUniform(image) }
        return read
    }

    /// The text lines in a picture (the reading pen, what Cookie saw). Throws when no recognizer ran.
    static func lines(in image: CGImage) async throws -> [CookieTextLine] {
        let read = try await self.read(image, faces: false)
        guard read.textRuns.contains(where: { $0 != nil }) else { throw CocoaError(.featureUnsupported) }
        return read.lines
    }

    /// A JPEG or PNG Cookie took, as an image.
    static func image(from data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    // MARK: In this process

    private static func readNow(_ image: CGImage, faces: Bool) throws -> CookieScreenRead {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        var read = CookieScreenRead()
        var levels: [VNRequestTextRecognitionLevel] = state == .ready ? [.accurate, .fast] : [.fast]
        while let level = levels.first {
            levels.removeFirst()
            do {
                let found = try recognize(handler, level: level)
                read.textRuns.append(found.count)
                if !found.isEmpty {
                    read.lines = found.map(line)
                    break
                }
            } catch {
                read.textRuns.append(nil)
                if level == .accurate {
                    current.withLock { $0 = .unavailable }
                    print("⚠️ Vision text: accurate failed, reading with fast from now on: \(error)")
                }
            }
        }
        if read.lines.isEmpty {
            let rectangles = VNDetectTextRectanglesRequest()
            read.textRectangles = (try? handler.perform([rectangles])).map { (rectangles.results ?? []).count }
            read.nearUniform = nearlyUniform(image)
        }
        if faces {
            let request = VNDetectFaceRectanglesRequest()
            read.faces = (try? handler.perform([request])).map { (request.results ?? []).map(\.boundingBox) }
        }
        return read
    }

    private static func recognize(_ handler: VNImageRequestHandler, level: VNRequestTextRecognitionLevel) throws -> [VNRecognizedText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = false
        try handler.perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first }
    }

    private static func line(_ recognized: VNRecognizedText) -> CookieTextLine {
        let text = recognized.string
        let words = CookieTextLine.wordRanges(in: text).compactMap { range -> CookieTextWord? in
            let lower = String.Index(utf16Offset: range.lowerBound, in: text), upper = String.Index(utf16Offset: range.upperBound, in: text)
            guard let box = try? recognized.boundingBox(for: lower..<upper)?.boundingBox else { return nil }
            return CookieTextWord(start: range.lowerBound, end: range.upperBound, box: box)
        }
        let whole = (try? recognized.boundingBox(for: text.startIndex..<text.endIndex)?.boundingBox)
            ?? words.dropFirst().reduce(words.first?.box ?? .zero) { $0.union($1.box) }
        return CookieTextLine(text: text, box: whole, words: words)
    }

    /// Few edges anywhere: a picture of one colour (or a gentle gradient), which really has no
    /// text. Grey at 256 pixels wide; an edge is a step of more than 32 of 255 between neighbours.
    static func nearlyUniform(_ image: CGImage) -> Bool {
        let width = 256, height = max(1, Int((Double(image.height) / Double(max(1, image.width)) * 256).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        return CookieEdges.fraction(gray: pixels, width: width, height: height) < 0.002
    }

    /// A few words in black on white, enough to make the model load.
    private static func sample() -> CGImage? {
        let width = 320, height = 64
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Cookie reads this",
                                                                       attributes: [.init(kCTFontAttributeName as String): font]))
        context.textPosition = CGPoint(x: 12, y: 22)
        CTLineDraw(line, context)
        return context.makeImage()
    }
}

/// The share of neighbouring pixel pairs (across and down) whose grey steps by more than 32.
enum CookieEdges {
    static func fraction(gray: [UInt8], width: Int, height: Int) -> Double {
        guard width > 1, height > 1, gray.count >= width * height else { return 1 }
        var edges = 0, pairs = 0
        for y in 0..<height {
            for x in 0..<width {
                let here = Int(gray[y * width + x])
                if x + 1 < width { pairs += 1; if abs(here - Int(gray[y * width + x + 1])) > 32 { edges += 1 } }
                if y + 1 < height { pairs += 1; if abs(here - Int(gray[(y + 1) * width + x])) > 32 { edges += 1 } }
            }
        }
        return Double(edges) / Double(max(1, pairs))
    }
}
