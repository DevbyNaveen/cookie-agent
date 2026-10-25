//
//  VisionWorker.swift
//  cookie-sense
//
//  Text lines with a box per word, faces, and text rectangles. The accurate
//  model is warmed at start and used only once it has read its warm-up
//  sample; until then, and after it fails, text is read with fast. A read
//  reports how each check went (Cookie's `CookieScreenRead`), never just what
//  it found.
//
//  VN requests, not the macOS 15 Swift `RecognizeTextRequest`: measured on an
//  M4 on macOS 27.0 (2026-10-24), the Swift request at `.fast` returned no
//  lines, without an error, on a picture the VN request read 29 lines from in
//  0.2 s — the silent empty read the redactor must never trust. Accurate fails
//  there with e5rt error 13 after ~26 s on every device it lists (Neural
//  Engine, GPU, CPU), so pinning it to another device doesn't help either.
//

import CoreGraphics
import CoreText
import Foundation
import Vision

actor VisionWorker {
    enum State: String { case warming, ready, unavailable }
    /// Fast only until Cookie asks for the accurate model (`warm`).
    private(set) var state = State.unavailable
    var stateName: String { state.rawValue }

    // MARK: Warm-up

    /// Loads the accurate model off this actor (a cold load took ~26 s on an M4): reads go on
    /// with fast meanwhile, and switch to accurate only once it has read its warm-up sample.
    nonisolated func warm(id: String) {
        Task.detached(priority: .utility) {
            await self.startWarming()
            let started = Date()
            let outcome = Self.loadAccurate()
            await self.warmed(failure: outcome, seconds: Date().timeIntervalSince(started))
            Wire.reply(id, ["accurate": await self.stateName, "failure": outcome ?? NSNull()])
        }
    }

    /// Loads the accurate model on a sample; nil when it read the sample, else why not.
    nonisolated static func loadAccurate() -> String? {
        let started = Date()
        let probe = VNRecognizeTextRequest()
        probe.recognitionLevel = .accurate
        let devices = ((try? probe.supportedComputeStageDevices[.main]) ?? []).map(\.description).joined(separator: ", ")
        log("text recognition can run on: \(devices.isEmpty ? "none listed" : devices)")
        guard let sample = sample() else { return "no sample image" }
        do {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: sample, options: [:]).perform([request])
            if (request.results ?? []).isEmpty { return "read nothing from its sample" }
            log(String(format: "accurate loaded in %.1f s", Date().timeIntervalSince(started)))
            return nil
        } catch {
            return "\(error)"
        }
    }

    private func startWarming() {
        if state == .unavailable { state = .warming }
    }

    private func warmed(failure: String?, seconds: Double) {
        guard state == .warming else { return }
        if let failure { return markUnavailable(failure) }
        state = .ready
        log(String(format: "accurate ready after %.1f s", seconds))
    }

    private func markUnavailable(_ why: String) {
        state = .unavailable
        log("accurate unavailable (\(why)), reading with fast")
    }

    // MARK: Reading

    /// Accurate once warm, and fast too whenever accurate failed or read nothing; faces with the
    /// first text request (Vision runs requests on one image best together); the separate text
    /// detector when no line was read.
    func read(id: String, request: [String: Any], pixels: Data) {
        guard let image = Self.image(request, pixels: pixels) else { return Wire.fail(id, "not a picture") }
        let faces = request["faces"] as? Bool ?? false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        var lines: [[String: Any]] = []
        var textRuns: [Any] = []
        var faceBoxes: [CGRect]?
        var facesPending = faces
        var levels: [VNRequestTextRecognitionLevel] = state == .ready ? [.accurate, .fast] : [.fast]
        while let level = levels.first {
            levels.removeFirst()
            do {
                let found: [VNRecognizedText]
                if facesPending {
                    let together = try recognizeWithFaces(handler, level: level)
                    found = together.text
                    faceBoxes = together.faces
                    facesPending = false
                } else {
                    found = try recognize(handler, level: level)
                }
                textRuns.append(found.count)
                if !found.isEmpty {
                    lines = found.map(Self.line)
                    break
                }
            } catch {
                textRuns.append(NSNull())
                if level == .accurate { markUnavailable("failed on a read: \(error)") }
            }
        }
        if facesPending { faceBoxes = detectFaces(handler) }
        var read: [String: Any] = ["lines": lines, "textRuns": textRuns, "nearUniform": false]
        read["faces"] = faceBoxes.map { $0.map(Self.json) as Any } ?? (faces ? NSNull() : [] as [Any])
        if lines.isEmpty {
            let rectangles = VNDetectTextRectanglesRequest()
            if (try? handler.perform([rectangles])) != nil { read["textRectangles"] = (rectangles.results ?? []).count }
        }
        Wire.reply(id, ["read": read, "accurate": state.rawValue])
    }

    private func textRequest(_ level: VNRequestTextRecognitionLevel) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = false
        return request
    }

    private func recognize(_ handler: VNImageRequestHandler, level: VNRequestTextRecognitionLevel) throws -> [VNRecognizedText] {
        let request = textRequest(level)
        try handler.perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first }
    }

    private func detectFaces(_ handler: VNImageRequestHandler) -> [CGRect]? {
        let request = VNDetectFaceRectanglesRequest()
        guard (try? handler.perform([request])) != nil else { return nil }
        return (request.results ?? []).map(\.boundingBox)
    }

    /// Text and faces in one `perform`. If it throws, they are tried apart, so a face failure
    /// can't be taken for a text failure (or the other way round).
    private func recognizeWithFaces(_ handler: VNImageRequestHandler, level: VNRequestTextRecognitionLevel) throws -> (text: [VNRecognizedText], faces: [CGRect]?) {
        let text = textRequest(level), faces = VNDetectFaceRectanglesRequest()
        do {
            try handler.perform([text, faces])
            return ((text.results ?? []).compactMap { $0.topCandidates(1).first }, (faces.results ?? []).map(\.boundingBox))
        } catch {
            return (try recognize(handler, level: level), detectFaces(handler))
        }
    }

    // MARK: Shapes

    /// One line as Cookie's `CookieTextLine`: text, box, a box per word (UTF-16 ranges).
    private static func line(_ candidate: VNRecognizedText) -> [String: Any] {
        let text = candidate.string
        var words: [[String: Any]] = []
        var start: Int?
        var offset = 0
        var index = text.startIndex
        var startIndex = text.startIndex
        func close(at end: Int, _ endIndex: String.Index) {
            guard let open = start else { return }
            if let box = try? candidate.boundingBox(for: startIndex..<endIndex)?.boundingBox {
                words.append(["start": open, "end": end, "box": json(box)])
            }
            start = nil
        }
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                close(at: offset, index)
            } else if start == nil {
                start = offset
                startIndex = index
            }
            offset += character.utf16.count
            index = text.index(after: index)
        }
        close(at: offset, text.endIndex)
        let whole = (try? candidate.boundingBox(for: text.startIndex..<text.endIndex)?.boundingBox) ?? .zero
        return ["text": text, "box": json(whole), "words": words]
    }
    /// CGRect as Foundation's Codable writes it, so Cookie decodes it as one: [[x, y], [w, h]].
    private static func json(_ rect: CGRect) -> [[Double]] {
        [[rect.origin.x, rect.origin.y], [rect.size.width, rect.size.height]]
    }

    /// The picture Cookie sent: its raw pixels and their layout, no re-encoding.
    private static func image(_ request: [String: Any], pixels: Data) -> CGImage? {
        guard let width = request["width"] as? Int, let height = request["height"] as? Int,
              let bytesPerRow = request["bytesPerRow"] as? Int, let bitsPerComponent = request["bitsPerComponent"] as? Int,
              let bitsPerPixel = request["bitsPerPixel"] as? Int, let bitmapInfo = request["bitmapInfo"] as? UInt32,
              width > 0, height > 0, pixels.count >= bytesPerRow * height,
              let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        let space = (request["colorSpace"] as? String).flatMap { CGColorSpace(name: $0 as CFString) } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CGImage(width: width, height: height, bitsPerComponent: bitsPerComponent, bitsPerPixel: bitsPerPixel,
                       bytesPerRow: bytesPerRow, space: space, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// A few words in black on white, enough to make the model load.
    nonisolated private static func sample() -> CGImage? {
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

/// Logs go to stderr, which Cookie prints with its own.
func log(_ message: String) {
    FileHandle.standardError.write(Data("👁️ cookie-sense: \(message)\n".utf8))
}
