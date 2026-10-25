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

enum CookieReadingPen {
    struct Line {
        let rect: CGRect
        /// Indices in the whitespace/quote-normalized phrase, preserving real line breaks.
        let characters: Range<Int>
    }

    static let maxPhrases = 8
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
                     mainHeight: CGFloat) async -> [[Line]?] {
        await Task.detached(priority: .userInitiated) {
            let texts = app.map(textElements(app:)) ?? []
            var recognized: [Int: [CookieTextLine]] = [:]
            var places: [[Line]?] = []
            for phrase in phrases {
                let needle = Folded([phrase]).characters
                guard needle.count >= 2 else { places.append(nil); continue }
                var found = texts.flatMap { appLines(needle, in: $0, mainHeight: mainHeight) }
                if found.isEmpty {
                    for (index, capture) in captures.enumerated() {
                        if recognized[index] == nil { recognized[index] = await recognize(capture) }
                        found += screenshotLines(needle, in: recognized[index] ?? [], capture: capture)
                    }
                }
                places.append(found.min { distance($0, pointer) < distance($1, pointer) })
            }
            return places
        }.value
    }

    /// One phrase's underlines: each line its own mark, drawn when the voice reaches the words
    /// that start it and inked over the time those words take to say.
    @MainActor
    static func marks(lines: [Line], phrase: String, offset: Int, spokenLength: Int) -> [CookieResolvedDrawing] {
        let folded = Folded([phrase])
        return lines.compactMap { found in
            guard !found.characters.isEmpty, found.characters.upperBound <= folded.origins.count else { return nil }
            let lower = folded.origins[found.characters.lowerBound].range.lowerBound.utf16Offset(in: phrase)
            let upper = folded.origins[found.characters.upperBound - 1].range.upperBound.utf16Offset(in: phrase)
            let line = found.rect
            let display = NSScreen.screens.first { $0.frame.intersects(line) }?.frame ?? NSScreen.main?.frame ?? .zero
            var mark = CookieResolvedDrawing(geometry: .underline(from: CGPoint(x: line.minX, y: line.minY - 1),
                                                                  to: CGPoint(x: line.maxX, y: line.minY - 1)),
                                             text: "", displayFrame: display)
            mark.offset = min(offset + lower, spokenLength)
            mark.readRange = mark.offset..<max(mark.offset + 1, min(offset + upper, spokenLength))
            mark.readSeconds = min(4, max(0.3, Double(upper - lower) / charactersPerSecond))
            return mark
        }
    }

    /// Match the quote immediately after the tag, never a later repeated phrase.
    /// Exact UTF-16 correspondence is required for playback-driven ink; paraphrases use
    /// the ordinary drawing animation instead of pretending they share character timing.
    static func spokenRange(of phrase: String, in spoken: String, near offset: Int) -> Range<Int>? {
        let text = spoken as NSString
        guard offset >= 0, offset < text.length else { return nil }
        let tail = text.substring(from: offset)
        let leading = tail.prefix { $0.isWhitespace }.utf16.count
        let start = offset + leading
        guard start + phrase.utf16.count <= text.length,
              text.substring(with: NSRange(location: start, length: phrase.utf16.count)) == phrase else { return nil }
        return start..<(start + phrase.utf16.count)
    }

    private static func distance(_ lines: [Line], _ point: CGPoint) -> CGFloat {
        guard let first = lines.first?.rect else { return .infinity }
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
    private static func appLines(_ needle: [Character], in text: TextElement, mainHeight: CGFloat) -> [[Line]] {
        let folded = Folded([text.text])
        return folded.ranges(of: needle).prefix(3).compactMap { match -> [Line]? in
            let lower = folded.origins[match.lowerBound].range.lowerBound, upper = folded.origins[match.upperBound - 1].range.upperBound
            let location = text.text.utf16.distance(from: text.text.startIndex, to: lower)
            let length = text.text.utf16.distance(from: lower, to: upper)
            guard let rects = lineRects(text.element, CFRange(location: location, length: length)),
                  rects.allSatisfy({ text.window.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }) else { return nil }
            return rects.compactMap { item in
                let indices = match.filter { index in
                    let start = folded.origins[index].range.lowerBound.utf16Offset(in: text.text)
                    return item.characters.contains(start)
                }
                guard let first = indices.first, let last = indices.last else { return nil }
                return Line(rect: CookieDrawingResolver.appKit(item.rect, mainHeight: mainHeight),
                            characters: (first - match.lowerBound)..<(last - match.lowerBound + 1))
            }
        }
    }

    /// The screen rects (CG global) of a character range, one per line it wraps across. Without
    /// line attributes the range's bounds are used only when they are one line tall.
    private static func lineRects(_ element: AXUIElement, _ range: CFRange) -> [Line]? {
        let end = range.location + range.length
        if let first = line(element, forIndex: range.location), let last = line(element, forIndex: end - 1),
           last >= first, last - first < maxLines {
            var rects: [Line] = []
            for number in first...last {
                guard let line = self.range(element, forLine: number) else { return nil }
                let lower = max(line.location, range.location), upper = min(line.location + line.length, end)
                guard upper > lower else { continue }
                guard let rect = bounds(element, CFRange(location: lower, length: upper - lower)) else { return nil }
                rects.append(Line(rect: rect, characters: lower..<upper))
            }
            return rects.isEmpty ? nil : rects
        }
        guard let whole = bounds(element, range), let glyph = bounds(element, CFRange(location: range.location, length: 1)),
              whole.height < glyph.height * 1.6 else { return nil }
        return [Line(rect: whole, characters: range.location..<end)]
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

    static func parameterized(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success else { return nil }
        return value
    }

    // MARK: The screenshot (Vision)

    /// Text lines read from a screenshot, accurate (word-precise boxes) once the model is warm.
    private static func recognize(_ capture: CompanionScreenCapture) async -> [CookieTextLine] {
        guard let image = CookieVisionText.image(from: capture.imageData) else { return [] }
        return (try? await CookieVisionText.lines(in: image)) ?? []
    }

    /// Each place the phrase is in a screenshot's text, read across line breaks, as one AppKit rect
    /// per recognised line it touches.
    static func screenshotLines(_ needle: [Character], in lines: [CookieTextLine], capture: CompanionScreenCapture) -> [[Line]] {
        let folded = Folded(lines.map(\.text))
        let exact = folded.ranges(of: needle).prefix(3).compactMap { match -> [Line]? in
            var rects: [Line] = []
            var index = match.lowerBound
            while index < match.upperBound {
                let piece = folded.origins[index].piece
                var last = index
                while last + 1 < match.upperBound, folded.origins[last + 1].piece == piece { last += 1 }
                if piece >= 0 {
                    let range = folded.origins[index].range.lowerBound..<folded.origins[last].range.upperBound
                    // Normalised, bottom-left origin → screenshot pixels, top-left → AppKit.
                    guard let box = lines[piece].boundingBox(for: range) else { return nil }
                    let width = CGFloat(capture.screenshotWidthInPixels), height = CGFloat(capture.screenshotHeightInPixels)
                    let topLeft = CookieDrawingResolver.global(CGPoint(x: box.minX * width, y: (1 - box.maxY) * height), in: capture)
                    let bottomRight = CookieDrawingResolver.global(CGPoint(x: box.maxX * width, y: (1 - box.minY) * height), in: capture)
                    rects.append(Line(rect: CGRect(x: topLeft.x, y: bottomRight.y, width: bottomRight.x - topLeft.x, height: topLeft.y - bottomRight.y),
                                      characters: (index - match.lowerBound)..<(last - match.lowerBound + 1)))
                }
                index = last + 1
            }
            return rects.isEmpty || rects.count > maxLines ? nil : rects
        }
        if !exact.isEmpty { return exact }
        // Fast Vision confuses letters in small terminal fonts. Recover only a unique,
        // long multiword quote, never a short label or a changed number.
        let phrase = String(needle)
        guard needle.count >= 12, phrase.split(separator: " ").count >= 2 else { return [] }
        let wordCount = phrase.split(separator: " ").count
        // Several word windows on one line can match the same words; they are one place. Two places
        // anywhere are ambiguous, and nothing is drawn.
        var best: (line: Int, range: NSRange, distance: Int, rects: [Line])?
        for (lineIndex, line) in lines.enumerated() {
            let words = CookieTextLine.wordRanges(in: line.text)
            for count in max(1, wordCount - 1)...(wordCount + 1) where words.count >= count {
            for start in 0...(words.count - count) {
                let lower = words[start].lowerBound, upper = words[start + count - 1].upperBound
                let nsRange = NSRange(location: lower, length: upper - lower)
                let source = (line.text as NSString).substring(with: nsRange)
                guard let distance = ocrDistance(source, expected: phrase), let range = Range(nsRange, in: line.text),
                      let box = line.boundingBox(for: range) else { continue }
                if let current = best {
                    let samePlace = current.line == lineIndex && NSIntersectionRange(current.range, nsRange).length > 0
                    guard samePlace else { return [] }
                    guard distance < current.distance else { continue }
                }
                let width = CGFloat(capture.screenshotWidthInPixels), height = CGFloat(capture.screenshotHeightInPixels)
                let top = CookieDrawingResolver.global(CGPoint(x: box.minX * width, y: (1 - box.maxY) * height), in: capture)
                let bottom = CookieDrawingResolver.global(CGPoint(x: box.maxX * width, y: (1 - box.minY) * height), in: capture)
                best = (lineIndex, nsRange, distance, [Line(rect: CGRect(x: top.x, y: bottom.y, width: bottom.x - top.x, height: top.y - bottom.y),
                                                            characters: 0..<needle.count)])
            }
            }
        }
        return best.map { [$0.rects] } ?? []
    }

    static func toleratesOCR(_ source: String, expected: String) -> Bool { ocrDistance(source, expected: expected) != nil }

    /// How many characters fast Vision got wrong, when it's plausibly the same text: at most one slip
    /// per word and two in all, never in a word under five letters ("not"/"now", "is"/"in" change the
    /// meaning; a long word with one wrong letter doesn't), and the same digits. Nil otherwise.
    static func ocrDistance(_ source: String, expected: String) -> Int? {
        let a = Folded([source]).characters, b = Folded([expected]).characters
        guard b.count >= 12, b.contains(" "),
              a.filter({ $0.isNumber }) == b.filter({ $0.isNumber }) else { return nil }
        let limit = min(2, max(1, b.count / 24))
        guard abs(a.count - b.count) <= limit else { return nil }
        // Levenshtein with the path kept, so each slip can be charged to the expected word it falls in.
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { table[i][0] = i }
        for j in 0...b.count { table[0][j] = j }
        // a is at least 10 long: b is 12+ and the lengths differ by two at most.
        for i in 1...a.count { for j in 1...b.count {
            table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
        } }
        let distance = table[a.count][b.count]
        guard distance <= limit else { return nil }
        // Which word of the expected text each position belongs to (a space goes with the word before it).
        var wordOf: [Int] = [], word = 0
        for character in b { wordOf.append(word); if character == " " { word += 1 } }
        let wordLengths = b.split(separator: " ", omittingEmptySubsequences: false).map(\.count)
        var slips: [Int: Int] = [:]
        var i = a.count, j = b.count
        while i > 0 || j > 0 {
            if i > 0, j > 0, table[i][j] == table[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1) {
                if a[i - 1] != b[j - 1] { slips[wordOf[j - 1], default: 0] += 1 }
                i -= 1; j -= 1
            } else if j > 0, table[i][j] == table[i][j - 1] + 1 {
                slips[wordOf[j - 1], default: 0] += 1; j -= 1
            } else {
                // A character Vision added (a split word): charged to the word it landed in.
                slips[wordOf[max(0, j - 1)], default: 0] += 1; i -= 1
            }
        }
        for (word, count) in slips where count > 1 || wordLengths[word] < 5 { return nil }
        return distance
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
