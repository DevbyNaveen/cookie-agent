//
//  CookieVisionText.swift
//  Cookie
//
//  The one text recognizer the app reads screenshots with. Vision's accurate
//  model loads on first use: on an M4 that took 13–28 s in a fresh process and
//  sometimes failed outright (e5rt error 13), and in that process every later
//  accurate call failed too; warm, it reads a screen in ~0.15 s. So it is
//  warmed once at launch, off the main thread, and nothing waits on it: until
//  it is ready, and for good once it has failed or the warm-up ran past 40 s,
//  text is read with .fast (0.04–0.45 s, fewer lines). A .fast failure is the
//  caller's to handle — the redactor then refuses to send the picture.
//

import CoreText
import Foundation
import os
import Vision

enum CookieVisionText {
    enum State { case warming, ready, unavailable }

    private static let current = OSAllocatedUnfairLock(initialState: State.warming)
    static var state: State { current.withLock { $0 } }

    /// Starts the accurate model loading. Called once, at launch.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            let started = Date()
            do {
                guard let image = sample() else { throw CocoaError(.featureUnsupported) }
                _ = try recognize(VNImageRequestHandler(cgImage: image, options: [:]), level: .accurate)
                let ready = current.withLock { state -> Bool in
                    guard state == .warming else { return false }
                    state = .ready
                    return true
                }
                print(ready ? "👁️ Vision text: accurate ready after \(String(format: "%.1f", Date().timeIntervalSince(started))) s"
                            : "👁️ Vision text: accurate loaded after the 40 s limit, staying on fast")
            } catch {
                current.withLock { $0 = .unavailable }
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

    /// The lines in the handler's image, best candidate each. Accurate once warm, else fast; an
    /// accurate failure marks it unavailable and the same image is read again with fast.
    /// Throws only when fast fails too. Synchronous CPU work: never on the main thread.
    static func recognize(_ handler: VNImageRequestHandler) throws -> [VNRecognizedText] {
        if state == .ready {
            do { return try recognize(handler, level: .accurate) } catch {
                current.withLock { $0 = .unavailable }
                print("⚠️ Vision text: accurate failed, reading with fast from now on: \(error)")
            }
        }
        return try recognize(handler, level: .fast)
    }

    private static func recognize(_ handler: VNImageRequestHandler, level: VNRequestTextRecognitionLevel) throws -> [VNRecognizedText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = false
        try handler.perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first }
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
