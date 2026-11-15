//
//  CookieMath.swift
//  Cookie
//
//  A small math typesetter for `equation` cards, no dependencies: a TeX subset
//  (fractions, scripts, roots, Greek, operators and relations, sums, products
//  and integrals with limits, parentheses that grow, matrices up to 3×3,
//  \text{}, a few accents) read into a tree, then laid out the way TeX does it —
//  italic letters, upright numbers and names, the four spacing widths between
//  classes of atom, scripts shrunk and raised from the baseline, everything
//  centred on the math axis. Glyphs come out as outlines (CoreText, the system
//  serif), rules and grown delimiters as pen strokes for Cookie's ink.
//
//  A part of the equation can carry an id, \id{m}{m}, so the voice can reveal
//  and highlight it on its words; with no ids at all, each side of every = and
//  + is a part of its own. Anything outside the subset, or a character no font
//  can draw, is a `Failure` with the reason, and the card shows the source as
//  written instead of broken glyphs.
//

import AppKit
import CoreText

enum CookieMath {
    /// TeX's atom classes, which decide the space between neighbours.
    enum Kind: Int, Equatable { case ord, op, bin, rel, open, close, punct, inner }

    enum Style: Int, Equatable {
        case display, text, script, scriptScript
        var scale: CGFloat { [1, 1, 0.7, 0.5][rawValue] }
        /// Where this style's scripts are set.
        var script: Style { rawValue < 2 ? .script : .scriptScript }
        /// Where a fraction's numerator and denominator are set.
        var fraction: Style { self == .display ? .text : self == .text ? .script : .scriptScript }
        var tight: Bool { rawValue >= 2 }
    }

    enum Accent: String, Equatable { case vec, hat, bar, dot }

    indirect enum Node: Equatable {
        case atom(String, Kind, italic: Bool)
        /// ∑ ∏ ∫ ∬ ∮: drawn large, limits above and below (sums, products) or beside (integrals).
        case large(String)
        /// sin, log, lim …: upright; `limits` names go above and below in display (lim, max, min).
        case function(String, limits: Bool)
        case text(String)
        case group([Node])
        case fraction(Node, Node)
        case root(Node, index: Node?)
        case scripts(Node, sup: Node?, sub: Node?)
        case fenced(String, Node, String)
        /// Rows of cells; `cases` sets them left aligned behind one brace.
        case matrix([[Node]], open: String, close: String, cases: Bool)
        case accent(Accent, Node)
        case term(String, Node)
        /// Space, in em.
        case space(CGFloat)
    }

    struct Failure: Error, Equatable { let reason: String }

    /// One mark on the page: a run of glyphs (its origin on the baseline), or a pen stroke, in
    /// points from the equation's own origin (left edge, on the baseline, y down).
    struct Piece: Equatable {
        enum Shape: Equatable {
            case glyphs(String, size: CGFloat, italic: Bool)
            /// Points from `origin`; `smooth` curves through them, otherwise straight with corners.
            case stroke([CGPoint], smooth: Bool, pen: CGFloat)
        }
        var shape: Shape
        var origin: CGPoint
        var term: String?
        /// Stable across states for the same mark (a term's glyphs by term, the rest by text and
        /// count), so a morph moves it instead of fading it.
        var key = ""

        /// Where the mark's ink is, in the equation's points.
        var bounds: CGRect {
            switch shape {
            case .glyphs(let text, let size, let italic):
                let box = (try? CookieMath.glyph(text, size: size, italic: italic))?.bounds ?? .zero
                return box.offsetBy(dx: origin.x, dy: origin.y)
            case .stroke(let points, _, let pen):
                let xs = points.map(\.x), ys = points.map(\.y)
                return CGRect(x: (xs.min() ?? 0) + origin.x - pen, y: (ys.min() ?? 0) + origin.y - pen,
                              width: (xs.max() ?? 0) - (xs.min() ?? 0) + 2 * pen, height: (ys.max() ?? 0) - (ys.min() ?? 0) + 2 * pen)
            }
        }
    }

    /// A typeset equation: its extent around the baseline, its marks, and where each part is.
    struct Layout: Equatable {
        var width: CGFloat
        var ascent: CGFloat
        var descent: CGFloat
        var pieces: [Piece]
        /// Each part's ink, in the equation's points.
        var terms: [String: CGRect]
        /// The parts left to right.
        var order: [String]
        var size: CGSize { CGSize(width: width, height: ascent + descent) }
    }

    struct Typeset {
        var layout: Layout?
        var failure: String?
        var repairs: [String] = []
        /// The equation in words, for VoiceOver and summaries.
        var spoken: String
        /// For each part: its words (when the reader names none).
        var termWords: [String: String] = [:]
    }

    static let maxLength = 300
    static let maxDepth = 14
    static let baseSize: CGFloat = 24
    static let maxWidth: CGFloat = 520
    static let minSize: CGFloat = 15

    /// Reads and lays out `tex`; on a failure the card shows the source as written.
    static func typeset(_ tex: String) -> Typeset {
        var parser = Parser(tex)
        let nodes: [Node]
        do { nodes = try parser.parse() } catch {
            return Typeset(layout: nil, failure: (error as? Failure)?.reason ?? "can't be read", repairs: parser.repairs, spoken: tex)
        }
        var tree = nodes
        if !tree.contains(where: Self.hasTerm) { tree = Self.autoTerms(tree) }
        var result = Typeset(layout: nil, failure: nil, repairs: parser.repairs, spoken: Speech.words(tree))
        for case .term(let id, let inner) in Self.flatTerms(tree) where result.termWords[id] == nil { result.termWords[id] = Speech.words([inner]) }
        do {
            var size = baseSize
            var layout = try Layouter(size: size).finish(tree)
            if layout.width > maxWidth {
                size = max(minSize, (baseSize * maxWidth / layout.width).rounded(.down))
                layout = try Layouter(size: size).finish(tree)
                guard layout.width <= maxWidth else { throw Failure(reason: "too wide for a card even at \(Int(minSize)) pt; split it into states") }
                result.repairs.append("tex: set at \(Int(size)) pt to fit the card")
            }
            result.layout = layout
        } catch {
            result.failure = (error as? Failure)?.reason ?? "can't be drawn"
        }
        return result
    }

    static func hasTerm(_ node: Node) -> Bool {
        switch node {
        case .term: return true
        case .group(let xs): return xs.contains(where: hasTerm)
        case .fraction(let a, let b): return hasTerm(a) || hasTerm(b)
        case .root(let a, let i): return hasTerm(a) || i.map(hasTerm) == true
        case .scripts(let a, let p, let b): return hasTerm(a) || p.map(hasTerm) == true || b.map(hasTerm) == true
        case .fenced(_, let a, _), .accent(_, let a): return hasTerm(a)
        case .matrix(let rows, _, _, _): return rows.joined().contains(where: hasTerm)
        default: return false
        }
    }

    /// Every term anywhere in the tree, outermost first.
    static func flatTerms(_ nodes: [Node]) -> [Node] {
        nodes.flatMap { node -> [Node] in
            switch node {
            case .term: return [node]
            case .group(let xs): return flatTerms(xs)
            case .fraction(let a, let b): return flatTerms([a, b])
            case .root(let a, let i): return flatTerms([a] + (i.map { [$0] } ?? []))
            case .scripts(let a, let p, let b): return flatTerms([a] + [p, b].compactMap { $0 })
            case .fenced(_, let a, _), .accent(_, let a): return flatTerms([a])
            case .matrix(let rows, _, _, _): return flatTerms(Array(rows.joined()))
            default: return []
            }
        }
    }

    /// With no ids written, the top line is cut before each relation and each + or −: E, = mc².
    static func autoTerms(_ nodes: [Node]) -> [Node] {
        var chunks: [[Node]] = [[]]
        for node in nodes {
            if case .atom(_, let kind, _) = node, kind == .rel || kind == .bin, !(chunks.last?.isEmpty ?? true) { chunks.append([]) }
            chunks[chunks.count - 1].append(node)
        }
        guard chunks.count > 1 else { return nodes }
        return chunks.enumerated().map { .term("t\($0.offset + 1)", .group($0.element)) }
    }

    // MARK: - Glyphs

    struct Glyph {
        let path: CGPath
        let advance: CGFloat
        /// Ink bounds from the origin (y down); a run with no ink is zero height on the baseline.
        let bounds: CGRect
    }

    private static let lock = NSLock()
    private static var glyphs: [String: Glyph] = [:]
    private static var fonts: [String: NSFont] = [:]

    /// The system serif (New York), italic for variables.
    static func font(size: CGFloat, italic: Bool) -> NSFont {
        let key = "\(size)|\(italic)"
        lock.lock(); defer { lock.unlock() }
        if let font = fonts[key] { return font }
        let base = NSFont.systemFont(ofSize: size)
        var descriptor = base.fontDescriptor.withDesign(.serif) ?? NSFontDescriptor(name: "Times New Roman", size: size)
        if italic { descriptor = descriptor.withSymbolicTraits(.italic) }
        let font = NSFont(descriptor: descriptor, size: size) ?? base
        fonts[key] = font
        return font
    }

    /// The outline of `text` set in one line; a character no font has is a failure, never a box.
    static func glyph(_ text: String, size: CGFloat, italic: Bool) throws -> Glyph {
        let key = "\(text)|\(size)|\(italic)"
        lock.lock()
        if let cached = glyphs[key] { lock.unlock(); return cached }
        lock.unlock()
        let font = font(size: size, italic: italic)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTFontAttributeName as String] else { continue }
            let runFont = value as! CTFont
            let name = CTFontCopyPostScriptName(runFont) as String
            let count = CTRunGetGlyphCount(run)
            var ids = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &ids)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for index in 0..<count {
                guard ids[index] != 0, !name.contains("LastResort") else {
                    throw Failure(reason: "\"\(text)\" has no glyph to draw it with")
                }
                var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: positions[index].x, ty: -positions[index].y)
                if let outline = CTFontCreatePathForGlyph(runFont, ids[index], &transform) { path.addPath(outline) }
            }
        }
        let ink = path.isEmpty ? CGRect(x: 0, y: 0, width: advance, height: 0) : path.boundingBoxOfPath
        let glyph = Glyph(path: path, advance: advance, bounds: ink)
        lock.lock(); glyphs[key] = glyph; lock.unlock()
        return glyph
    }

    // MARK: - Symbols

    static let greek: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π",
        "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ",
        "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ",
        "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    ]
    static let symbols: [String: (String, Kind)] = [
        "times": ("×", .bin), "cdot": ("·", .bin), "pm": ("±", .bin), "mp": ("∓", .bin), "div": ("÷", .bin), "circ": ("∘", .bin),
        "ast": ("∗", .bin), "cup": ("∪", .bin), "cap": ("∩", .bin), "wedge": ("∧", .bin), "vee": ("∨", .bin), "oplus": ("⊕", .bin),
        "le": ("≤", .rel), "leq": ("≤", .rel), "ge": ("≥", .rel), "geq": ("≥", .rel), "ne": ("≠", .rel), "neq": ("≠", .rel),
        "approx": ("≈", .rel), "sim": ("∼", .rel), "simeq": ("≃", .rel), "equiv": ("≡", .rel), "propto": ("∝", .rel),
        "to": ("→", .rel), "rightarrow": ("→", .rel), "leftarrow": ("←", .rel), "Rightarrow": ("⇒", .rel), "Leftarrow": ("⇐", .rel),
        "leftrightarrow": ("↔", .rel), "Leftrightarrow": ("⇔", .rel), "implies": ("⇒", .rel), "iff": ("⇔", .rel), "mapsto": ("↦", .rel),
        "in": ("∈", .rel), "notin": ("∉", .rel), "subset": ("⊂", .rel), "subseteq": ("⊆", .rel), "ll": ("≪", .rel), "gg": ("≫", .rel),
        "infty": ("∞", .ord), "partial": ("∂", .ord), "nabla": ("∇", .ord), "hbar": ("ℏ", .ord), "ell": ("ℓ", .ord),
        "cdots": ("⋯", .inner), "ldots": ("…", .inner), "dots": ("…", .inner), "degree": ("°", .ord), "prime": ("′", .ord),
        "forall": ("∀", .ord), "exists": ("∃", .ord), "emptyset": ("∅", .ord), "angle": ("∠", .ord), "triangle": ("△", .ord),
        "langle": ("⟨", .open), "rangle": ("⟩", .close), "lfloor": ("⌊", .open), "rfloor": ("⌋", .close),
        "lceil": ("⌈", .open), "rceil": ("⌉", .close), "%": ("%", .ord), "#": ("#", .ord), "&": ("&", .ord), "_": ("_", .ord),
        "{": ("{", .open), "}": ("}", .close), "|": ("‖", .ord), "$": ("$", .ord),
    ]
    static let larges: [String: String] = ["sum": "∑", "prod": "∏", "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮", "coprod": "∐", "bigcup": "⋃", "bigcap": "⋂"]
    static let functions: Set<String> = ["sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh",
                                         "log", "ln", "lg", "exp", "det", "dim", "deg", "gcd", "arg", "Pr"]
    static let limitFunctions: Set<String> = ["lim", "max", "min", "sup", "inf", "limsup", "liminf"]
    static let spaces: [String: CGFloat] = [",": 3.0 / 18, ":": 4.0 / 18, ">": 4.0 / 18, ";": 5.0 / 18, "!": -3.0 / 18, " ": 0.25,
                                            "quad": 1, "qquad": 2, "thinspace": 3.0 / 18, "enspace": 0.5]
    /// Characters typed straight in, and what they are.
    static let characters: [Character: (String, Kind)] = [
        "+": ("+", .bin), "-": ("−", .bin), "−": ("−", .bin), "=": ("=", .rel), "<": ("<", .rel), ">": (">", .rel), ":": (":", .rel),
        ",": (",", .punct), ";": (";", .punct), "!": ("!", .close), "?": ("?", .close), "/": ("/", .ord), "|": ("|", .ord),
        "(": ("(", .open), ")": (")", .close), "[": ("[", .open), "]": ("]", .close),
        "×": ("×", .bin), "·": ("·", .bin), "±": ("±", .bin), "÷": ("÷", .bin), "≤": ("≤", .rel), "≥": ("≥", .rel), "≠": ("≠", .rel),
        "≈": ("≈", .rel), "→": ("→", .rel), "∝": ("∝", .rel), "≡": ("≡", .rel), "∈": ("∈", .rel), "⇒": ("⇒", .rel), "∞": ("∞", .ord),
        "∂": ("∂", .ord), "∇": ("∇", .ord), "°": ("°", .ord), "′": ("′", .ord), "%": ("%", .ord),
    ]
    /// Delimiters, as written after \left / \right or in a matrix environment, to the drawn character.
    static let delimiters: [String: String] = ["(": "(", ")": ")", "[": "[", "]": "]", "{": "{", "}": "}", "|": "|", "‖": "‖",
                                               "langle": "⟨", "rangle": "⟩", "lvert": "|", "rvert": "|", "lVert": "‖", "rVert": "‖",
                                               "vert": "|", "Vert": "‖", ".": "", "<": "⟨", ">": "⟩", "⟨": "⟨", "⟩": "⟩"]

    // MARK: - Reading

    struct Parser {
        enum Token: Equatable {
            case char(Character)
            case command(String)
            case open, close, sup, sub, amp, newline
            /// The braced text after \text, \mathrm, \id, \begin or \end, as written.
            case raw(String, String)
        }

        private var tokens: [Token] = []
        private var index = 0
        private var depth = 0
        private var inTerm: String?
        /// "(" and "[" tokens that have a partner at the same level: those pairs grow with their contents.
        private var paired: Set<Int> = []
        var repairs: [String] = []
        private var failure: Failure?

        static let rawCommands: Set<String> = ["text", "textrm", "mathrm", "textit", "mathit", "operatorname", "mbox", "id", "begin", "end", "textnormal"]

        init(_ source: String) {
            var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
            for (open, close) in [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)"), ("$", "$")]
            where text.count > open.count + close.count && text.hasPrefix(open) && text.hasSuffix(close) {
                text = String(text.dropFirst(open.count).dropLast(close.count)).trimmingCharacters(in: .whitespaces)
                repairs.append("tex: took off the \(open)…\(close) around it")
                break
            }
            if text.count > CookieMath.maxLength { failure = Failure(reason: "longer than \(CookieMath.maxLength) characters") }
            tokens = Self.tokens(text, repairs: &repairs)
            paired = Self.pairs(tokens)
        }

        private static func tokens(_ text: String, repairs: inout [String]) -> [Token] {
            let chars = Array(text)
            var tokens: [Token] = []
            var at = 0
            while at < chars.count {
                let c = chars[at]
                switch c {
                case "\\":
                    at += 1
                    guard at < chars.count else { tokens.append(.command("\\")); continue }
                    if chars[at] == "\\" { tokens.append(.newline); at += 1; continue }
                    guard chars[at].isLetter else { tokens.append(.command(String(chars[at]))); at += 1; continue }
                    var name = ""
                    while at < chars.count, chars[at].isLetter, chars[at].isASCII { name.append(chars[at]); at += 1 }
                    if rawCommands.contains(name) {
                        var look = at
                        while look < chars.count, chars[look] == " " { look += 1 }
                        if look < chars.count, chars[look] == "{" {
                            var level = 1, end = look + 1
                            while end < chars.count, level > 0 {
                                if chars[end] == "\\", end + 1 < chars.count { end += 2; continue }
                                if chars[end] == "{" { level += 1 } else if chars[end] == "}" { level -= 1 }
                                end += 1
                            }
                            if level > 0 { repairs.append("tex: closed the { after \\\(name)") }
                            let inner = String(chars[(look + 1)..<(level > 0 ? end : end - 1)])
                            tokens.append(.raw(name, inner))
                            at = end
                            continue
                        }
                    }
                    tokens.append(.command(name))
                case "{": tokens.append(.open); at += 1
                case "}": tokens.append(.close); at += 1
                case "^": tokens.append(.sup); at += 1
                case "_": tokens.append(.sub); at += 1
                case "&": tokens.append(.amp); at += 1
                case " ", "\n", "\t", "~": at += 1
                default: tokens.append(.char(c)); at += 1
                }
            }
            return tokens
        }

        /// Matches each ( with its ) and [ with its ] inside the same braces, skipping the ones
        /// that follow \left, \right or open \sqrt's index.
        private static func pairs(_ tokens: [Token]) -> Set<Int> {
            var stack: [[(Int, Character)]] = [[]]
            var result: Set<Int> = []
            for (index, token) in tokens.enumerated() {
                if index > 0, case .command(let name) = tokens[index - 1],
                   name == "left" || name == "right" || name.hasPrefix("big") || name.hasPrefix("Big") || name == "sqrt" { continue }
                switch token {
                case .open: stack.append([])
                case .close: if stack.count > 1 { stack.removeLast() }
                case .char("("), .char("["): stack[stack.count - 1].append((index, token == .char("(") ? "(" : "["))
                case .char(")"), .char("]"):
                    let want: Character = token == .char(")") ? "(" : "["
                    if let last = stack[stack.count - 1].last, last.1 == want {
                        result.insert(last.0)
                        stack[stack.count - 1].removeLast()
                    }
                default: break
                }
            }
            return result
        }

        mutating func parse() throws -> [Node] {
            if let failure { throw failure }
            var nodes: [Node] = []
            while index < tokens.count {
                let (more, stop) = try list(until: [])
                nodes += more
                if stop == nil { break }
            }
            return nodes
        }

        private var peek: Token? { index < tokens.count ? tokens[index] : nil }

        private func isStop(_ token: Token, _ stops: Set<String>) -> String? {
            switch token {
            case .close where stops.contains("}"): return "}"
            case .amp where stops.contains("&"): return "&"
            case .newline where stops.contains("\\\\"): return "\\\\"
            case .command("right") where stops.contains("right"): return "right"
            case .raw("end", _) where stops.contains("end"): return "end"
            case .char(")") where stops.contains(")"): return ")"
            case .char("]") where stops.contains("]"): return "]"
            default: return nil
            }
        }

        /// Items up to one of `stops` (left for the caller) or the end.
        private mutating func list(until stops: Set<String>) throws -> (nodes: [Node], stop: String?) {
            depth += 1
            defer { depth -= 1 }
            guard depth <= CookieMath.maxDepth else { throw Failure(reason: "nested more than \(CookieMath.maxDepth) deep") }
            var nodes: [Node] = []
            while let token = peek {
                if let stop = isStop(token, stops) { return (nodes, stop) }
                switch token {
                case .sup, .sub:
                    index += 1
                    let argument = try self.argument(script: true)
                    try attach(argument, sup: token == .sup, to: &nodes)
                case .char("'"):
                    index += 1
                    try attach(.atom("′", .ord, italic: false), sup: true, to: &nodes, prime: true)
                default:
                    if let node = try item(stops: stops) { nodes.append(node) }
                }
            }
            return (nodes, nil)
        }

        private mutating func attach(_ script: Node, sup: Bool, to nodes: inout [Node], prime: Bool = false) throws {
            let base = nodes.popLast() ?? .group([])
            if case .scripts(let inner, let up, let down) = base {
                if sup {
                    if let up {
                        // f'^2 is fine (a prime then a power); x^2^3 isn't.
                        let primed = up == .atom("′", .ord, italic: false) || { if case .group(let xs) = up { return xs.first == .atom("′", .ord, italic: false) }; return false }()
                        guard prime || primed else {
                            throw Failure(reason: "two superscripts on one thing; group them with braces")
                        }
                        nodes.append(.scripts(inner, sup: .group([up, script]), sub: down))
                    } else { nodes.append(.scripts(inner, sup: script, sub: down)) }
                } else {
                    guard down == nil else { throw Failure(reason: "two subscripts on one thing; group them with braces") }
                    nodes.append(.scripts(inner, sup: up, sub: script))
                }
            } else {
                nodes.append(.scripts(base, sup: sup ? script : nil, sub: sup ? nil : script))
            }
        }

        /// What a command or a script takes: a braced group, or one token (a run of digits for a
        /// script, the way it's meant: x^10 is x to the ten).
        private mutating func argument(script: Bool = false) throws -> Node {
            guard let token = peek else { throw Failure(reason: "something is missing at the end") }
            switch token {
            case .open:
                index += 1
                let (nodes, stop) = try list(until: ["}"])
                if stop == nil { repairs.append("tex: closed a { that was left open") } else { index += 1 }
                return .group(nodes)
            case .char(let c) where c.isNumber:
                var digits = String(c)
                index += 1
                if script {
                    while case .char(let next)? = peek, next.isNumber { digits.append(next); index += 1 }
                    if digits.count > 1 { repairs.append("tex: read ^\(digits) as ^{\(digits)}") }
                }
                return .atom(digits, .ord, italic: false)
            case .close, .amp, .newline, .sup, .sub:
                throw Failure(reason: "something is missing before \(token == .close ? "}" : token == .amp ? "&" : "a script")")
            default:
                guard let node = try item(stops: []) else { throw Failure(reason: "something is missing") }
                return node
            }
        }

        private mutating func item(stops: Set<String>) throws -> Node? {
            guard let token = peek else { return nil }
            index += 1
            switch token {
            case .open:
                let (nodes, stop) = try list(until: ["}"])
                if stop == nil { repairs.append("tex: closed a { that was left open") } else { index += 1 }
                return .group(nodes)
            case .close:
                repairs.append("tex: left out a } with no {")
                return nil
            case .amp, .newline:
                throw Failure(reason: "& and \\\\ only work inside a matrix")
            case .sup, .sub:
                return nil
            case .raw(let name, let body):
                return try raw(name, body)
            case .char(let c):
                return try character(c, at: index - 1, stops: stops)
            case .command(let name):
                return try command(name, stops: stops)
            }
        }

        private mutating func character(_ c: Character, at position: Int, stops: Set<String>) throws -> Node? {
            if c.isNumber || c == "." {
                var number = String(c)
                while case .char(let next)? = peek, next.isNumber || (next == "." && number.last?.isNumber == true) {
                    number.append(next); index += 1
                }
                return .atom(number, .ord, italic: false)
            }
            if (c == "(" || c == "["), paired.contains(position) {
                let close = c == "(" ? ")" : "]"
                let (nodes, stop) = try list(until: [close])
                if stop == close { index += 1 }
                return .fenced(String(c), .group(nodes), close)
            }
            if c == "*" {
                repairs.append("tex: drew * as ·")
                return .atom("·", .bin, italic: false)
            }
            if let (glyph, kind) = CookieMath.characters[c] { return .atom(glyph, kind, italic: false) }
            if c.isLetter {
                // Latin and lowercase Greek letters are variables (italic); capital Greek stands upright.
                let greekCapital = ("Α"..."Ω").contains(String(c))
                return .atom(String(c), .ord, italic: !greekCapital)
            }
            return .atom(String(c), .ord, italic: false)
        }

        private mutating func raw(_ name: String, _ body: String) throws -> Node? {
            switch name {
            case "text", "textrm", "mbox", "textnormal": return .text(body)
            case "mathrm", "operatorname": return .function(body, limits: false)
            case "textit", "mathit":
                return .group(body.filter { !$0.isWhitespace }.map { .atom(String($0), .ord, italic: true) })
            case "id":
                let id = body.trimmingCharacters(in: .whitespaces)
                guard !id.isEmpty, id.count <= 24, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
                    throw Failure(reason: "\\id{\(body)}: a part's id is up to 24 letters, digits or dashes")
                }
                if let outer = inTerm {
                    repairs.append("tex: parts can't nest, so \\id{\(id)} is drawn as part of \(outer)")
                    return try argument()
                }
                inTerm = id
                defer { inTerm = nil }
                return .term(id, try argument())
            case "begin": return try matrix(body)
            default: throw Failure(reason: "\\end{\(body)} without its \\begin")
            }
        }

        private mutating func command(_ name: String, stops: Set<String>) throws -> Node? {
            if let letter = CookieMath.greek[name] { return .atom(letter, .ord, italic: name.first!.isLowercase) }
            if let (glyph, kind) = CookieMath.symbols[name] { return .atom(glyph, kind, italic: false) }
            if let large = CookieMath.larges[name] { return .large(large) }
            if CookieMath.functions.contains(name) { return .function(name, limits: false) }
            if CookieMath.limitFunctions.contains(name) { return .function(name, limits: true) }
            if let space = CookieMath.spaces[name] { return .space(space) }
            switch name {
            case "frac", "dfrac", "tfrac", "cfrac":
                let top = try argument()
                return .fraction(top, try argument())
            case "binom":
                let top = try argument()
                return .fenced("(", .matrix([[top], [try argument()]], open: "", close: "", cases: false), ")")
            case "sqrt":
                var rootIndex: Node?
                if case .char("[")? = peek {
                    index += 1
                    let (nodes, stop) = try list(until: ["]"])
                    if stop == "]" { index += 1 } else { repairs.append("tex: closed the [ of \\sqrt") }
                    rootIndex = .group(nodes)
                }
                return .root(try argument(), index: rootIndex)
            case "left":
                let open = try delimiter(after: "\\left")
                let (nodes, stop) = try list(until: ["right"])
                var close = ""
                if stop == "right" {
                    index += 1
                    close = try delimiter(after: "\\right")
                } else { repairs.append("tex: added the \\right that \\left was missing") }
                return .fenced(open, .group(nodes), close)
            case "right":
                throw Failure(reason: "\\right without a \\left")
            case "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr", "Biggl", "Biggr", "middle":
                repairs.append("tex: \\\(name) left out; brackets size themselves")
                return nil
            case "vec", "overrightarrow": return .accent(.vec, try argument())
            case "hat", "widehat": return .accent(.hat, try argument())
            case "bar", "overline": return .accent(.bar, try argument())
            case "dot": return .accent(.dot, try argument())
            case "mathbf", "boldsymbol", "bm", "textbf", "mathsf", "mathcal", "displaystyle", "textstyle":
                repairs.append("tex: \\\(name) drawn in the ordinary face")
                if name == "displaystyle" || name == "textstyle" { return nil }
                return try argument()
            case "limits", "nolimits", "nonumber", "notag":
                return nil
            case "\\":
                throw Failure(reason: "a lone backslash")
            default:
                throw Failure(reason: "\\\(name) isn't supported")
            }
        }

        private mutating func delimiter(after what: String) throws -> String {
            guard let token = peek else { throw Failure(reason: "\(what) needs a bracket after it") }
            index += 1
            let written: String
            switch token {
            case .char(let c): written = String(c)
            case .command(let name): written = name
            default: throw Failure(reason: "\(what) needs a bracket after it")
            }
            guard let drawn = CookieMath.delimiters[written] else { throw Failure(reason: "\(what)\(written) isn't a bracket Cookie draws") }
            return drawn
        }

        private static let environments: [String: (String, String)] = [
            "matrix": ("", ""), "pmatrix": ("(", ")"), "bmatrix": ("[", "]"), "Bmatrix": ("{", "}"), "vmatrix": ("|", "|"),
            "Vmatrix": ("‖", "‖"), "smallmatrix": ("", ""), "cases": ("{", ""),
        ]

        private mutating func matrix(_ environment: String) throws -> Node {
            let name = environment.trimmingCharacters(in: .whitespaces)
            guard let (open, close) = Self.environments[name] else { throw Failure(reason: "\\begin{\(name)} isn't supported (matrix, pmatrix, bmatrix, vmatrix, cases)") }
            var rows: [[Node]] = [[]]
            while true {
                let (nodes, stop) = try list(until: ["&", "\\\\", "end"])
                rows[rows.count - 1].append(.group(nodes))
                guard let stop else { repairs.append("tex: added the missing \\end{\(name)}"); break }
                index += 1
                if stop == "&" { continue }
                if stop == "\\\\" { rows.append([]); continue }
                if case .raw("end", let ended) = tokens[index - 1], ended.trimmingCharacters(in: .whitespaces) != name {
                    throw Failure(reason: "\\begin{\(name)} ends with \\end{\(ended)}")
                }
                break
            }
            // A last \\ before \end makes an empty row; it isn't one.
            if rows.count > 1, rows.last == [.group([])] { rows.removeLast() }
            let columns = rows.map(\.count).max() ?? 0
            guard rows.count <= 3, columns <= 3 else {
                throw Failure(reason: "matrices are up to 3×3; this one is \(rows.count)×\(columns)")
            }
            return .matrix(rows, open: open, close: close, cases: name == "cases")
        }
    }

    // MARK: - Words

    enum Speech {
        static let names: [String: String] = [
            "=": "equals", "+": "plus", "−": "minus", "×": "times", "·": "times", "±": "plus or minus", "÷": "divided by", "/": "over",
            "<": "is less than", ">": "is greater than", "≤": "is at most", "≥": "is at least", "≠": "is not equal to", "≈": "is about",
            "→": "goes to", "⇒": "implies", "∝": "is proportional to", "≡": "is identical to", "∈": "is in", "∞": "infinity",
            "∂": "partial", "∇": "del", "′": "prime", "°": "degrees", "∼": "is similar to",
        ]
        static func words(_ nodes: [Node]) -> String {
            nodes.map(word).filter { !$0.isEmpty }.joined(separator: " ").replacingOccurrences(of: "  ", with: " ")
        }
        static func word(_ node: Node) -> String {
            switch node {
            case .atom(let text, _, _):
                if let name = names[text] { return name }
                if let greek = CookieMath.greek.first(where: { $0.value == text })?.key { return greek }
                return text
            case .large(let symbol): return ["∑": "the sum", "∏": "the product", "∫": "the integral", "∬": "the double integral", "∮": "the loop integral"][symbol] ?? symbol
            case .function(let name, _): return name
            case .text(let text): return text
            case .group(let xs): return words(xs)
            case .fraction(let a, let b): return "\(word(a)) over \(word(b))"
            case .root(let a, let index):
                let which = index.map(word)
                return (which == nil || which == "2" ? "the square root of " : which == "3" ? "the cube root of " : "the \(which!) root of ") + word(a)
            case .scripts(let base, let sup, let sub):
                var text = word(base)
                if case .large = base {
                    if let sub { text += " from \(word(sub))" }
                    if let sup { text += " to \(word(sup))" }
                    return text + " of"
                }
                if let sub { text += " sub \(word(sub))" }
                if let sup {
                    let power = word(sup)
                    text += power == "2" ? " squared" : power == "3" ? " cubed" : power == "prime" ? " prime" : " to the power \(power)"
                }
                return text
            case .fenced(_, let inner, _): return word(inner)
            case .matrix(let rows, _, _, let cases):
                return (cases ? "cases: " : "a \(rows.count) by \(rows.map(\.count).max() ?? 0) matrix: ")
                    + rows.map { $0.map(word).joined(separator: ", ") }.joined(separator: "; ")
            case .accent(let accent, let inner):
                return accent == .vec ? "vector \(word(inner))" : "\(word(inner)) \(accent.rawValue)"
            case .term(_, let inner): return word(inner)
            case .space: return ""
            }
        }
    }

    // MARK: - Layout

    /// A laid-out piece of math: its width, how far it rises above and falls below the baseline,
    /// its marks, and its class on each side (for the space beside it).
    struct Box {
        var width: CGFloat = 0
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var pieces: [Piece] = []
        /// How far an italic letter leans past its advance (a superscript clears it).
        var italic: CGFloat = 0
        var left: Kind = .ord
        var right: Kind = .ord
        /// A sum or lim in display: its scripts go above and below.
        var limits = false
        /// An integral: its lower limit tucks in under the curve.
        var subKern: CGFloat = 0
        var isSpace = false

        mutating func place(_ other: Box, x: CGFloat, y: CGFloat) {
            pieces += other.pieces.map { piece in
                var moved = piece
                moved.origin.x += x
                moved.origin.y += y
                return moved
            }
            ascent = max(ascent, other.ascent - y)
            descent = max(descent, other.descent + y)
        }

        mutating func stroke(_ points: [CGPoint], smooth: Bool, pen: CGFloat, term: String?) {
            pieces.append(Piece(shape: .stroke(points, smooth: smooth, pen: pen), origin: .zero, term: term))
            for point in points {
                ascent = max(ascent, -point.y + pen / 2)
                descent = max(descent, point.y + pen / 2)
            }
        }
    }

    struct Layouter {
        let size: CGFloat

        func em(_ style: Style) -> CGFloat { size * style.scale }
        func axis(_ style: Style) -> CGFloat { 0.25 * em(style) }
        func pen(_ style: Style) -> CGFloat { max(1.1, 0.055 * em(style)) }

        func finish(_ nodes: [Node]) throws -> Layout {
            let box = try row(nodes, .display, term: nil)
            var counts: [String: Int] = [:]
            var pieces = box.pieces
            for index in pieces.indices {
                let what: String
                switch pieces[index].shape {
                case .glyphs(let text, _, _): what = text
                case .stroke(_, let smooth, _): what = smooth ? "curve" : "line"
                }
                let base = "\(pieces[index].term ?? "")|\(what)"
                pieces[index].key = base + "#\(counts[base, default: 0])"
                counts[base, default: 0] += 1
            }
            var terms: [String: CGRect] = [:]
            for piece in pieces {
                guard let term = piece.term else { continue }
                terms[term] = terms[term].map { $0.union(piece.bounds) } ?? piece.bounds
            }
            let order = terms.keys.sorted { (terms[$0]!.minX, $0) < (terms[$1]!.minX, $1) }
            return Layout(width: box.width, ascent: box.ascent, descent: box.descent, pieces: pieces, terms: terms, order: order)
        }

        /// TeX's table of spaces between classes (TeXbook ch. 18): 0 none, 1 thin, a/b/c thin,
        /// medium, thick only outside scripts. Rows are the left atom, columns the right.
        private static let table = ["01bc000a", "11*c000a", "bb**b**b", "cc*0c00c", "00*00000", "01bc000a", "aa*aaaaa", "a1bca0aa"].map(Array.init)

        func space(_ left: Kind, _ right: Kind, _ style: Style) -> CGFloat {
            let mu = em(style) / 18
            switch Self.table[left.rawValue][right.rawValue] {
            case "1": return 3 * mu
            case "a": return style.tight ? 0 : 3 * mu
            case "b": return style.tight ? 0 : 4 * mu
            case "c": return style.tight ? 0 : 5 * mu
            default: return 0
            }
        }

        func row(_ nodes: [Node], _ style: Style, term: String?) throws -> Box {
            // A part that holds several atoms lays them out with the line around it, so it spaces like them.
            var items: [(Node, String?)] = []
            for node in nodes {
                if case .term(let id, .group(let inner)) = node { items += inner.map { ($0, term ?? id) } }
                else { items.append((node, term)) }
            }
            var boxes = try items.map { try layout($0.0, style, term: $0.1) }
            // A + with nothing before it to add to is a sign, not an operator.
            let atoms = boxes.indices.filter { !boxes[$0].isSpace }
            for (position, index) in atoms.enumerated() where boxes[index].left == .bin {
                let before = position > 0 ? boxes[atoms[position - 1]].right : nil
                let after = position + 1 < atoms.count ? boxes[atoms[position + 1]].left : nil
                if before == nil || [.bin, .op, .rel, .open, .punct].contains(before!) || after == nil || [.rel, .close, .punct].contains(after!) {
                    boxes[index].left = .ord
                    boxes[index].right = .ord
                }
            }
            var result = Box()
            var previous: Kind?
            for box in boxes {
                if !box.isSpace {
                    if let previous { result.width += space(previous, box.left, style) }
                    previous = box.right
                }
                result.place(box, x: result.width, y: 0)
                result.width += box.width
                result.italic = box.italic
            }
            result.left = boxes.first { !$0.isSpace }?.left ?? .ord
            result.right = boxes.last { !$0.isSpace }?.right ?? .ord
            return result
        }

        func atom(_ text: String, _ style: Style, italic: Bool, kind: Kind, term: String?, scale: CGFloat = 1) throws -> Box {
            let size = em(style) * scale
            let glyph = try CookieMath.glyph(text, size: size, italic: italic)
            var box = Box(width: glyph.advance, ascent: max(0, -glyph.bounds.minY), descent: max(0, glyph.bounds.maxY))
            box.italic = italic ? max(0, glyph.bounds.maxX - glyph.advance) : 0
            box.pieces = [Piece(shape: .glyphs(text, size: size, italic: italic), origin: .zero, term: term)]
            box.left = kind
            box.right = kind
            return box
        }

        func layout(_ node: Node, _ style: Style, term: String?) throws -> Box {
            let e = em(style)
            switch node {
            case .atom(let text, let kind, let italic):
                return try atom(text, style, italic: italic, kind: kind, term: term)
            case .text(let text):
                return try atom(text.isEmpty ? " " : text, style, italic: false, kind: .ord, term: term)
            case .function(let name, let limits):
                var box = try atom(name, style, italic: false, kind: .op, term: term)
                box.limits = limits && style == .display
                return box
            case .large(let symbol):
                let integral = "∫∬∭∮".contains(symbol)
                let scale: CGFloat = style == .display ? (integral ? 1.75 : 1.4) : (integral ? 1.2 : 1.05)
                let size = e * scale
                let glyph = try CookieMath.glyph(symbol, size: size, italic: false)
                // Centred on the math axis.
                let dy = -axis(style) - glyph.bounds.midY
                var box = Box(width: max(glyph.advance, glyph.bounds.maxX), ascent: -(glyph.bounds.minY + dy), descent: glyph.bounds.maxY + dy)
                box.pieces = [Piece(shape: .glyphs(symbol, size: size, italic: false), origin: CGPoint(x: 0, y: dy), term: term)]
                box.left = .op; box.right = .op
                box.limits = style == .display && !integral
                if integral { box.italic = 0.08 * size; box.subKern = -0.22 * size }
                return box
            case .space(let width):
                var box = Box(width: width * e)
                box.isSpace = true
                return box
            case .group(let nodes):
                var box = try row(nodes, style, term: term)
                box.left = .ord; box.right = .ord
                return box
            case .term(let id, let inner):
                return try layout(inner, style, term: term ?? id)
            case .scripts(let baseNode, let supNode, let subNode):
                return try scripts(baseNode, supNode, subNode, style, term: term)
            case .fraction(let top, let bottom):
                let inner = style.fraction
                let num = try layout(top, inner, term: term), den = try layout(bottom, inner, term: term)
                let a = axis(style), thickness = 0.06 * e, clearance = style == .display ? 3 * thickness : thickness
                let up = max(style == .display ? 0.677 * e : 0.394 * e, a + thickness / 2 + clearance + num.descent)
                let down = max(style == .display ? 0.686 * e : 0.345 * e, den.ascent + clearance + thickness / 2 - a)
                let pad = 0.12 * e
                let width = max(num.width, den.width) + 2 * pad
                var box = Box(width: width)
                box.place(num, x: (width - num.width) / 2, y: -up)
                box.place(den, x: (width - den.width) / 2, y: down)
                box.stroke([CGPoint(x: pad * 0.4, y: -a), CGPoint(x: width - pad * 0.4, y: -a)], smooth: false, pen: pen(style), term: term)
                box.left = .inner; box.right = .inner
                return box
            case .root(let radicand, let indexNode):
                let body = try layout(radicand, style, term: term)
                let thickness = 0.055 * e
                let clearance = thickness + (style == .display ? 0.12 * e : 0.06 * e)
                let top = -(body.ascent + clearance + thickness)
                let bottom = body.descent + 0.04 * e
                let height = bottom - top
                let sign = 0.52 * e + min(0.25 * e, 0.05 * height)
                var shift: CGFloat = 0
                var index: Box?
                if let indexNode {
                    index = try layout(indexNode, .scriptScript, term: term)
                    shift = max(0, index!.width - 0.32 * sign)
                }
                var box = Box()
                let tick = top + 0.62 * height
                box.stroke([CGPoint(x: shift, y: tick + 0.04 * e), CGPoint(x: shift + 0.16 * sign, y: tick - 0.03 * e),
                            CGPoint(x: shift + 0.46 * sign, y: bottom), CGPoint(x: shift + sign, y: top),
                            CGPoint(x: shift + sign + body.width + 0.1 * e, y: top)], smooth: false, pen: pen(style), term: term)
                if let index { box.place(index, x: shift + 0.3 * sign - index.width, y: tick - 0.08 * e - index.descent) }
                box.place(body, x: shift + sign + 0.05 * e, y: 0)
                box.width = shift + sign + body.width + 0.16 * e
                return box
            case .fenced(let open, let inner, let close):
                let content = try layout(inner, style, term: term)
                return try fence(content, open: open, close: close, style, term: term, grow: false)
            case .matrix(let rows, let open, let close, let cases):
                let content = try matrix(rows, style, term: term, cases: cases)
                return try fence(content, open: open, close: close, style, term: term, grow: true)
            case .accent(let accent, let inner):
                var body = try layout(inner, style, term: term)
                let y = -(body.ascent + 0.12 * e)
                let lean = body.italic * 0.6
                let middle = body.width / 2 + lean
                let reach = max(body.width, 0.5 * e)
                switch accent {
                case .bar:
                    body.stroke([CGPoint(x: middle - reach / 2 + 0.04 * e, y: y), CGPoint(x: middle + reach / 2 - 0.02 * e, y: y)], smooth: false, pen: pen(style), term: term)
                case .vec:
                    let left = CGPoint(x: middle - reach / 2 + 0.04 * e, y: y), tip = CGPoint(x: middle + reach / 2 + 0.04 * e, y: y)
                    body.stroke([left, tip], smooth: false, pen: pen(style), term: term)
                    body.stroke([CGPoint(x: tip.x - 0.16 * e, y: y - 0.1 * e), tip, CGPoint(x: tip.x - 0.16 * e, y: y + 0.1 * e)], smooth: false, pen: pen(style), term: term)
                case .hat:
                    body.stroke([CGPoint(x: middle - 0.2 * e, y: y + 0.07 * e), CGPoint(x: middle, y: y - 0.1 * e), CGPoint(x: middle + 0.2 * e, y: y + 0.07 * e)], smooth: false, pen: pen(style), term: term)
                case .dot:
                    let r = 0.05 * e
                    body.stroke((0...8).map { CGPoint(x: middle + r * cos(CGFloat($0) * .pi / 4), y: y + r * sin(CGFloat($0) * .pi / 4)) }, smooth: true, pen: pen(style) * 1.6, term: term)
                }
                return body
            }
        }

        private func scripts(_ baseNode: Node, _ supNode: Node?, _ subNode: Node?, _ style: Style, term: String?) throws -> Box {
            let base = try layout(baseNode, style, term: term)
            let small = style.script
            let sup = try supNode.map { try layout($0, small, term: term) }
            let sub = try subNode.map { try layout($0, small, term: term) }
            let e = em(style)
            var box = Box()
            if base.limits {
                let width = max(base.width, sup?.width ?? 0, sub?.width ?? 0)
                box.place(base, x: (width - base.width) / 2, y: 0)
                if let sup { box.place(sup, x: (width - sup.width) / 2, y: -(base.ascent + 0.14 * e + sup.descent)) }
                if let sub { box.place(sub, x: (width - sub.width) / 2, y: base.descent + 0.12 * e + sub.ascent) }
                box.width = width
            } else {
                var up: CGFloat = 0, down: CGFloat = 0
                if let sup {
                    up = max(base.ascent - 0.3 * e, (style == .display ? 0.42 : style.tight ? 0.3 : 0.38) * e, sup.descent + 0.11 * e)
                }
                if let sub {
                    down = max(base.descent + 0.05 * e, (sup == nil ? 0.16 : 0.24) * e, sub.ascent - 0.36 * e)
                }
                if let sup, let sub {
                    let gap = (up - sup.descent) - (sub.ascent - down)
                    if gap < 0.16 * e { down += 0.16 * e - gap }
                }
                box.place(base, x: 0, y: 0)
                var end = base.width
                if let sup {
                    box.place(sup, x: base.width + base.italic, y: -up)
                    end = max(end, base.width + base.italic + sup.width)
                }
                if let sub {
                    box.place(sub, x: base.width + base.subKern, y: down)
                    end = max(end, base.width + base.subKern + sub.width)
                }
                box.width = end + 0.05 * e
            }
            box.left = base.left
            box.right = base.right
            return box
        }

        private func matrix(_ rows: [[Node]], _ style: Style, term: String?, cases: Bool) throws -> Box {
            let cellStyle: Style = style == .display ? .text : style
            let e = em(style)
            let cells = try rows.map { row in try row.map { try layout($0, cellStyle, term: term) } }
            let columns = cells.map(\.count).max() ?? 0
            let widths = (0..<columns).map { column in cells.map { column < $0.count ? $0[column].width : 0 }.max() ?? 0 }
            let gap = cases ? 1.0 * e : 0.9 * e
            var baselines: [CGFloat] = []
            for (index, row) in cells.enumerated() {
                let ascent = row.map(\.ascent).max() ?? 0
                if index == 0 { baselines.append(0); continue }
                let descent = cells[index - 1].map(\.descent).max() ?? 0
                baselines.append(baselines[index - 1] + max(1.2 * e, descent + 0.32 * e + ascent))
            }
            let top = -(cells.first?.map(\.ascent).max() ?? 0)
            let bottom = (baselines.last ?? 0) + (cells.last?.map(\.descent).max() ?? 0)
            let shift = -axis(style) - (top + bottom) / 2
            var box = Box()
            for (r, row) in cells.enumerated() {
                var x: CGFloat = 0
                for (c, cell) in row.enumerated() {
                    box.place(cell, x: x + (cases ? 0 : (widths[c] - cell.width) / 2), y: baselines[r] + shift)
                    x += widths[c] + gap
                }
            }
            box.width = widths.reduce(0, +) + gap * CGFloat(max(0, columns - 1))
            return box
        }

        /// Brackets around `content`: the font's own at ordinary height, drawn to fit when the
        /// content is taller (always for a matrix).
        private func fence(_ content: Box, open: String, close: String, _ style: Style, term: String?, grow: Bool) throws -> Box {
            let e = em(style), a = axis(style)
            let reach = max(content.ascent - a, content.descent + a)
            let ink = grow || reach > 0.62 * e
            let half = max(reach + 0.1 * e, 0.6 * e)
            func side(_ delimiter: String, opening: Bool) throws -> Box {
                guard !delimiter.isEmpty else { return Box(width: 0.12 * e) }
                guard ink else { return try atom(delimiter, style, italic: false, kind: opening ? .open : .close, term: term) }
                let base: CGFloat = ["(": 0.42, ")": 0.42, "[": 0.36, "]": 0.36, "{": 0.5, "}": 0.5, "|": 0.28, "‖": 0.4, "⟨": 0.42, "⟩": 0.42][delimiter] ?? 0.4
                let w = (base + min(0.22, 0.03 * half / e)) * e
                let top = -a - half, bottom = -a + half, middle = -a
                var box = Box(width: w)
                func x(_ fraction: CGFloat) -> CGFloat { w * fraction }
                switch delimiter {
                case "(", ")":
                    let points = (0...12).map { step -> CGPoint in
                        let t = CGFloat(step) / 12
                        let bulge = 0.62 * sin(.pi * t)
                        return CGPoint(x: x(delimiter == "(" ? 0.86 - bulge : 0.14 + bulge), y: top + (bottom - top) * t)
                    }
                    box.stroke(points, smooth: true, pen: pen(style) * 1.15, term: term)
                case "[", "]":
                    let outer = delimiter == "[" ? 0.8 : 0.2, inner = delimiter == "[" ? 0.28 : 0.72
                    box.stroke([CGPoint(x: x(outer), y: top), CGPoint(x: x(inner), y: top), CGPoint(x: x(inner), y: bottom), CGPoint(x: x(outer), y: bottom)],
                               smooth: false, pen: pen(style) * 1.1, term: term)
                case "{", "}":
                    let s: CGFloat = delimiter == "{" ? 1 : -1, c: CGFloat = delimiter == "{" ? 0 : 1
                    func bx(_ f: CGFloat) -> CGFloat { x(c + s * f) }
                    let q = (bottom - top) / 4
                    box.stroke([CGPoint(x: bx(0.85), y: top), CGPoint(x: bx(0.55), y: top + 0.15 * q), CGPoint(x: bx(0.5), y: top + q),
                                CGPoint(x: bx(0.48), y: middle - 0.35 * q), CGPoint(x: bx(0.15), y: middle), CGPoint(x: bx(0.48), y: middle + 0.35 * q),
                                CGPoint(x: bx(0.5), y: bottom - q), CGPoint(x: bx(0.55), y: bottom - 0.15 * q), CGPoint(x: bx(0.85), y: bottom)],
                               smooth: true, pen: pen(style), term: term)
                case "|":
                    box.stroke([CGPoint(x: x(0.5), y: top), CGPoint(x: x(0.5), y: bottom)], smooth: false, pen: pen(style), term: term)
                case "‖":
                    box.stroke([CGPoint(x: x(0.32), y: top), CGPoint(x: x(0.32), y: bottom)], smooth: false, pen: pen(style), term: term)
                    box.stroke([CGPoint(x: x(0.68), y: top), CGPoint(x: x(0.68), y: bottom)], smooth: false, pen: pen(style), term: term)
                default: // ⟨ ⟩
                    let outer = delimiter == "⟨" ? 0.8 : 0.2, inner = delimiter == "⟨" ? 0.2 : 0.8
                    box.stroke([CGPoint(x: x(outer), y: top), CGPoint(x: x(inner), y: middle), CGPoint(x: x(outer), y: bottom)], smooth: false, pen: pen(style), term: term)
                }
                box.left = opening ? .open : .close
                box.right = box.left
                return box
            }
            let left = try side(open, opening: true), right = try side(close, opening: false)
            var box = Box()
            box.place(left, x: 0, y: 0)
            let gap = ink ? 0.06 * e : 0
            box.place(content, x: left.width + gap, y: 0)
            box.place(right, x: left.width + content.width + 2 * gap, y: 0)
            box.width = left.width + content.width + 2 * gap + right.width
            box.left = .inner; box.right = .inner
            return box
        }
    }
}
