//
//  CookieReadingPen.swift
//  Cookie
//
//  Cookie reads along. A [READ:words] tag names text on the screen, written
//  where Cookie starts talking about it; her pen underlines exactly those
//  words, a line at a time, as the voice says them. The words are found where
//  the app keeps its text (Accessibility: an element's value, then the screen
//  bounds of that character range, line by line), else in the screenshot this
//  turn already took (Vision text recognition), else nowhere: an underline in
//  the wrong place is worse than none, so the tag is dropped.
//

import AppKit
import ApplicationServices
import Vision

enum CookieReadingPen {
    static let maxPhrases = 3
    static let maxLines = 4
    /// About how fast a voice reads (150 words a minute): characters a second.
    static let charactersPerSecond = 15.0

    /// The phrases a reply asked to underline, each with where its tag sat in the spoken text.
    static func phrases(in tags: [CookieReplyTag]) -> [(phrase: String, offset: Int)] {
        let read = tags.filter { $0.kind == "READ" }.map { (phrase: $0.body.trimmingCharacters(in: .whitespacesAndNewlines), offset: $0.offset) }
        return Array(read.filter { $0.phrase.count >= 2 && $0.phrase.count <= 300 }.prefix(maxPhrases))
    }

    /// Where each phrase is on screen, one AppKit rect per line, or nil when it can't be found
    /// for certain. Reads the app's text first, then the screenshots; off the main thread.
    /// - Parameters:
    ///   - app: the app the question is about; nil reads only the screenshots.
    ///   - pointer: the mouse (AppKit global): of several matches, the nearest wins.
    static func find(_ phrases: [String], app: pid_t?, captures: [CompanionScreenCapture], pointer: CGPoint,
                     mainHeight: CGFloat) async -> [[CGRect]?] {
        await Task.detached(priority: .userInitiated) {
            let texts = app.map(textElements(app:)) ?? []
            var recognized: [Int: [VNRecognizedText]] = [:]
            return phrases.map { phrase -> [CGRect]? in
                let needle = Folded([phrase]).characters
                guard needle.count >= 2 else { return nil }
                var found = texts.flatMap { appLines(needle, in: $0, mainHeight: mainHeight) }
                if found.isEmpty {
                    for (index, capture) in captures.enumerated() {
                        if recognized[index] == nil { recognized[index] = recognize(capture) }
                        found += screenshotLines(needle, in: recognized[index] ?? [], capture: capture)
                    }
                }
                return found.min { distance($0, pointer) < distance($1, pointer) }
            }
        }.value
    }

    /// One phrase's underlines: each line its own mark, drawn when the voice reaches the words
    /// that start it and inked over the time those words take to say.
    @MainActor
    static func marks(lines: [CGRect], phrase: String, offset: Int, spokenLength: Int) -> [CookieResolvedDrawing] {
        let total = max(1, lines.reduce(0) { $0 + $1.width })
        let count = Double(phrase.utf16.count)
        var before: CGFloat = 0
        return lines.map { line in
            let start = offset + Int((Double(before / total) * count).rounded())
            let characters = Double(line.width / total) * count
            before += line.width
            let display = NSScreen.screens.first { $0.frame.intersects(line) }?.frame ?? NSScreen.main?.frame ?? .zero
            var mark = CookieResolvedDrawing(geometry: .underline(from: CGPoint(x: line.minX, y: line.minY - 1),
                                                                  to: CGPoint(x: line.maxX, y: line.minY - 1)),
                                             text: "", displayFrame: display)
            mark.offset = min(start, spokenLength)
            mark.readSeconds = min(4, max(0.3, characters / charactersPerSecond))
            return mark
        }
    }

    private static func distance(_ lines: [CGRect], _ point: CGPoint) -> CGFloat {
        guard let first = lines.first else { return .infinity }
        return hypot(first.midX - point.x, first.midY - point.y)
    }

    // MARK: The app's own text (Accessibility)

    private struct TextElement {
        let element: AXUIElement
        let text: String
        /// Its window's frame (CG global): only words in view count.
        let window: CGRect
    }

    private static let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]

    /// The text-bearing elements of the app's focused window. Web areas (Safari, Chrome) are walked
    /// into: their words live in static text inside them. Chromium and Electron build the tree only
    /// when asked (`AXManualAccessibility`, as `look` does). A secure field's role is never read.
    private static func textElements(app pid: pid_t) -> [TextElement] {
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window = MacOperator.attribute(root, kAXFocusedWindowAttribute) as! AXUIElement?,
              let frame = MacOperator.frame(window) else { return [] }
        var found: [TextElement] = []
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        // ponytail: a 4,000-element walk; a huge page past that falls back to the screenshot.
        while !queue.isEmpty, visited < 4_000 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role = MacOperator.string(element, kAXRoleAttribute) ?? ""
            if textRoles.contains(role), let text = MacOperator.attribute(element, kAXValueAttribute) as? String, !text.isEmpty {
                found.append(TextElement(element: element, text: text, window: frame))
            }
            guard depth < 60, let children = MacOperator.attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            queue.append(contentsOf: children.prefix(400).map { ($0, depth + 1) })
        }
        return found
    }

    /// Each place the phrase is in one element's text, as that element's line rects (AppKit).
    private static func appLines(_ needle: [Character], in text: TextElement, mainHeight: CGFloat) -> [[CGRect]] {
        let folded = Folded([text.text])
        return folded.ranges(of: needle).prefix(3).compactMap { match -> [CGRect]? in
            let lower = folded.origins[match.lowerBound].range.lowerBound, upper = folded.origins[match.upperBound - 1].range.upperBound
            let location = text.text.utf16.distance(from: text.text.startIndex, to: lower)
            let length = text.text.utf16.distance(from: lower, to: upper)
            guard let rects = lineRects(text.element, CFRange(location: location, length: length)),
                  rects.allSatisfy({ text.window.contains(CGPoint(x: $0.midX, y: $0.midY)) }) else { return nil }
            return rects.map { CookieDrawingResolver.appKit($0, mainHeight: mainHeight) }
        }
    }

    /// The screen rects (CG global) of a character range, one per line it wraps across. Without
    /// line attributes the range's bounds are used only when they are one line tall.
    private static func lineRects(_ element: AXUIElement, _ range: CFRange) -> [CGRect]? {
        let end = range.location + range.length
        if let first = line(element, forIndex: range.location), let last = line(element, forIndex: end - 1),
           last >= first, last - first < maxLines {
            var rects: [CGRect] = []
            for number in first...last {
                guard let line = self.range(element, forLine: number) else { return nil }
                let lower = max(line.location, range.location), upper = min(line.location + line.length, end)
                guard upper > lower else { continue }
                guard let rect = bounds(element, CFRange(location: lower, length: upper - lower)) else { return nil }
                rects.append(rect)
            }
            return rects.isEmpty ? nil : rects
        }
        guard let whole = bounds(element, range), let glyph = bounds(element, CFRange(location: range.location, length: 1)),
              whole.height < glyph.height * 1.6 else { return nil }
        return [whole]
    }

    /// `kAXBoundsForRangeParameterizedAttribute`: an AXValue CFRange in, an AXValue CGRect out.
    static func bounds(_ element: AXUIElement, _ range: CFRange) -> CGRect? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range),
              let value = parameterized(element, kAXBoundsForRangeParameterizedAttribute, parameter),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.width > 1, rect.height > 1 else { return nil }
        return rect
    }

    /// `kAXLineForIndexParameterizedAttribute`: a character index in, its line number out.
    private static func line(_ element: AXUIElement, forIndex index: Int) -> Int? {
        (parameterized(element, kAXLineForIndexParameterizedAttribute, index as CFNumber) as? NSNumber)?.intValue
    }

    /// `kAXRangeForLineParameterizedAttribute`: a line number in, its character range out.
    private static func range(_ element: AXUIElement, forLine line: Int) -> CFRange? {
        guard let value = parameterized(element, kAXRangeForLineParameterizedAttribute, line as CFNumber),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    private static func parameterized(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success else { return nil }
        return value
    }

    // MARK: The screenshot (Vision)

    /// Text lines read from a screenshot. Accurate recognition: its boxes are word-precise.
    private static func recognize(_ capture: CompanionScreenCapture) -> [VNRecognizedText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(data: capture.imageData, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first }
    }

    /// Each place the phrase is in a screenshot's text, read across line breaks, as one AppKit rect
    /// per recognised line it touches.
    private static func screenshotLines(_ needle: [Character], in lines: [VNRecognizedText], capture: CompanionScreenCapture) -> [[CGRect]] {
        let folded = Folded(lines.map(\.string))
        return folded.ranges(of: needle).prefix(3).compactMap { match -> [CGRect]? in
            var rects: [CGRect] = []
            var index = match.lowerBound
            while index < match.upperBound {
                let piece = folded.origins[index].piece
                var last = index
                while last + 1 < match.upperBound, folded.origins[last + 1].piece == piece { last += 1 }
                if piece >= 0 {
                    let range = folded.origins[index].range.lowerBound..<folded.origins[last].range.upperBound
                    // Normalised, bottom-left origin → screenshot pixels, top-left → AppKit.
                    guard let box = try? lines[piece].boundingBox(for: range)?.boundingBox else { return nil }
                    let width = CGFloat(capture.screenshotWidthInPixels), height = CGFloat(capture.screenshotHeightInPixels)
                    let topLeft = CookieDrawingResolver.global(CGPoint(x: box.minX * width, y: (1 - box.maxY) * height), in: capture)
                    let bottomRight = CookieDrawingResolver.global(CGPoint(x: box.maxX * width, y: (1 - box.minY) * height), in: capture)
                    rects.append(CGRect(x: topLeft.x, y: bottomRight.y, width: bottomRight.x - topLeft.x, height: topLeft.y - bottomRight.y))
                }
                index = last + 1
            }
            return rects.isEmpty || rects.count > maxLines ? nil : rects
        }
    }
}

/// Text folded for matching as a reader would: lower case, any run of white space one space,
/// curly quotes and dashes plain. Each folded character remembers the piece and the range of the
/// original it came from; pieces are joined by a space that belongs to none (piece -1).
struct Folded {
    private(set) var characters: [Character] = []
    private(set) var origins: [(piece: Int, range: Range<String.Index>)] = []

    init(_ pieces: [String]) {
        for (piece, text) in pieces.enumerated() {
            if !characters.isEmpty, characters.last != " " {
                characters.append(" ")
                origins.append((-1, text.startIndex..<text.startIndex))
            }
            var index = text.startIndex
            while index < text.endIndex {
                let next = text.index(after: index)
                let character = text[index]
                if character.isWhitespace {
                    if !characters.isEmpty, characters.last != " " {
                        characters.append(" ")
                        origins.append((piece, index..<next))
                    }
                } else {
                    for folded in Self.fold(character) {
                        characters.append(folded)
                        origins.append((piece, index..<next))
                    }
                }
                index = next
            }
        }
        while characters.last == " " {
            characters.removeLast()
            origins.removeLast()
        }
    }

    private static func fold(_ character: Character) -> [Character] {
        switch character {
        case "\u{2018}", "\u{2019}", "\u{02BC}": return ["'"]
        case "\u{201C}", "\u{201D}": return ["\""]
        case "\u{2013}", "\u{2014}": return ["-"]
        default: return Array(character.lowercased())
        }
    }

    /// Where `needle` starts and ends in the folded text, every place it does.
    func ranges(of needle: [Character]) -> [Range<Int>] {
        guard !needle.isEmpty, needle.count <= characters.count else { return [] }
        return (0...(characters.count - needle.count)).filter { start in
            characters[start] == needle[0] && characters[start..<start + needle.count].elementsEqual(needle)
        }.map { $0..<$0 + needle.count }
    }
}
