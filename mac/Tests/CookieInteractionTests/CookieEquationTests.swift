import AppKit
import SwiftUI

/// Equation cards: the TeX subset read and typeset the way TeX does it (classes and their spaces,
/// scripts, fractions on the axis, limits, growing brackets, matrices), parts revealed and lit on
/// the speech clock, what's outside the subset shown as written, and the prompt's own example.
@MainActor
enum CookieEquationTests {
    static func run() {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            count += 1
        }
        func layout(_ tex: String) -> CookieMath.Layout {
            let typeset = CookieMath.typeset(tex)
            guard let layout = typeset.layout else { preconditionFailure("\(tex): \(typeset.failure ?? "?")") }
            return layout
        }
        func glyphs(_ layout: CookieMath.Layout, _ text: String) -> [CookieMath.Piece] {
            layout.pieces.filter { if case .glyphs(text, _, _) = $0.shape { return true }; return false }
        }
        func advance(_ text: String, italic: Bool, size: CGFloat = 24) -> CGFloat { try! CookieMath.glyph(text, size: size, italic: italic).advance }
        let em: CGFloat = CookieMath.baseSize, mu = em / 18

        // MARK: Typography
        let sum = layout("a+b")
        let plus = glyphs(sum, "+")[0], b = glyphs(sum, "b")[0]
        check(abs(plus.origin.x - (advance("a", italic: true) + 4 * mu)) < 0.01
              && abs(b.origin.x - (plus.origin.x + advance("+", italic: false) + 4 * mu)) < 0.01,
              "a binary operator gets a medium space either side")
        let unary = layout("-b")
        check(abs(glyphs(unary, "b")[0].origin.x - advance("−", italic: false)) < 0.01, "a leading minus is a sign: no space after it")
        let equals = layout("a=b")
        check(abs(glyphs(equals, "=")[0].origin.x - (advance("a", italic: true) + 5 * mu)) < 0.01, "a relation gets a thick space")
        if case .glyphs(_, _, let italic) = glyphs(equals, "a")[0].shape, case .glyphs(_, _, let upright) = layout("2").pieces[0].shape {
            check(italic && !upright, "variables are italic, numbers upright")
        }
        let greek = CookieMath.typeset(#"\alpha + \Omega"#).layout!
        if case .glyphs(_, _, let lower) = glyphs(greek, "α")[0].shape, case .glyphs(_, _, let capital) = glyphs(greek, "Ω")[0].shape {
            check(lower && !capital, "lowercase Greek is italic, capitals upright")
        }
        check(glyphs(layout(#"\sin x"#), "sin").first.map { if case .glyphs(_, _, let italic) = $0.shape { return !italic }; return false } == true,
              "function names stand upright")

        let power = layout("x^2"), sub = layout("x_i")
        let two = glyphs(power, "2")[0]
        if case .glyphs(_, let size, _) = two.shape { check(abs(size - em * 0.7) < 0.01, "a script is set at 70%") }
        check(two.origin.y < -0.38 * em && glyphs(sub, "i")[0].origin.y > 0.1 * em, "superscripts rise from the baseline, subscripts drop")

        let fraction = layout(#"\frac{a}{b}"#)
        let bar = fraction.pieces.first { if case .stroke = $0.shape { return true }; return false }!
        guard case .stroke(let barPoints, false, _) = bar.shape else { preconditionFailure("the bar is a straight stroke") }
        check(abs(barPoints[0].y + 0.25 * em) < 0.01, "the fraction bar sits on the math axis")
        check(glyphs(fraction, "a")[0].origin.y < -0.25 * em && glyphs(fraction, "b")[0].origin.y > 0, "numerator above the bar, denominator below")

        let limits = layout(#"\sum_{i=1}^{n} i"#)
        let sigma = glyphs(limits, "∑")[0].bounds, top = glyphs(limits, "n")[0].bounds, bottom = glyphs(limits, "1")[0].bounds
        check(top.maxY < sigma.minY && bottom.minY > sigma.maxY && abs(top.midX - sigma.midX) < 2,
              "a displayed sum's limits sit centred above and below it")
        let integral = layout(#"\int_0^1 x\,dx"#)
        let curve = glyphs(integral, "∫")[0].bounds, upper = glyphs(integral, "1")[0].bounds
        check(upper.minX > curve.midX && upper.midY < curve.midY, "an integral's limits go beside it")

        let quadratic = layout(#"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}"#)
        let strokes = quadratic.pieces.filter { if case .stroke = $0.shape { return true }; return false }
        check(strokes.count == 2 && !glyphs(quadratic, "±").isEmpty && quadratic.width < CookieMath.maxWidth, "the quadratic formula typesets: a bar and a root sign")
        check(glyphs(layout("(a+b)"), "(").count == 1 && glyphs(layout(#"\left(\frac{a}{b}\right)"#), "(").isEmpty
              && layout(#"(\frac{a}{b})"#).pieces.filter { if case .stroke(_, true, _) = $0.shape { return true }; return false }.count == 2,
              "brackets are the font's at ordinary height, and drawn to fit around a fraction")
        let matrix = layout(#"A = \begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix}"#)
        check(["1", "2", "3", "4"].allSatisfy { !glyphs(matrix, $0).isEmpty } && glyphs(matrix, "1")[0].origin.y < glyphs(matrix, "3")[0].origin.y
              && glyphs(matrix, "1")[0].origin.x < glyphs(matrix, "2")[0].origin.x, "a 2×2 matrix sets its rows and columns")
        check(CookieMath.typeset(#"\begin{bmatrix}1&2&3&4\end{bmatrix}"#).failure?.contains("up to 3×3") == true, "a matrix past 3×3 is refused with the reason")
        check(CookieMath.typeset(#"|x| = \begin{cases} x & x \ge 0 \\ -x & x < 0 \end{cases}"#).layout != nil, "cases typeset behind one brace")

        // MARK: Words
        check(CookieMath.typeset(#"\frac{a}{b}"#).spoken == "a over b" && CookieMath.typeset("x^2").spoken == "x squared"
              && CookieMath.typeset(#"\sqrt{x}"#).spoken == "the square root of x", "an equation is said in words: \(CookieMath.typeset(#"\frac{a}{b}"#).spoken)")

        // MARK: Outside the subset
        let unknown = CookieCard.read(#"{"kind":"equation","title":"T","tex":"\\foo{x} = 1"}"#)
        guard case .equation(let shownAsWritten)? = unknown.card?.content else { preconditionFailure("an unsupported equation is still a card: \(unknown.errors)") }
        check(shownAsWritten.layout == nil && unknown.repairs.contains { $0.contains("\\foo isn't supported") && $0.contains("shown as written") }
              && unknown.card!.elements == [.title, .value], "TeX outside the subset shows as its source, and says why")
        check(CookieMath.typeset("\\text{\u{E000}}").failure?.contains("no glyph") == true, "a character no font can draw never becomes a box")
        let messy = CookieMath.typeset("$x^10 + \\big( y$")
        check(messy.layout != nil && messy.repairs.contains { $0.contains("took off the $") } && messy.repairs.contains { $0.contains("^{10}") }
              && messy.repairs.contains { $0.contains("\\big left out") }, "clear intent is repaired and said: \(messy.repairs)")
        check(CookieMath.typeset("x^2^3").failure?.contains("two superscripts") == true && CookieMath.typeset("{x").repairs.contains { $0.contains("closed a {") },
              "a double superscript is refused; an unclosed brace is closed")
        check(CookieMath.typeset(#"\id{a}{x + \id{b}{y}}"#).repairs.contains { $0.contains("can't nest") }, "parts don't nest")
        check(CookieCard.read(#"{"kind":"equation","title":"T"}"#).errors.first?.hasPrefix("tex: required") == true, "an equation without tex is an error")

        // MARK: Parts on the speech clock
        let prompt = CompanionManager.companionVoiceResponseSystemPrompt
        let line = prompt.components(separatedBy: "\n").first { $0.contains("newton's second law [CARD") }!
        let example = String(line[line.range(of: "\"newton's second law [CARD")!.lowerBound...].dropFirst().dropLast())
        let split = CookieReplyTags.split(example)
        let newton = CookieCard(tag: split.tags.first { $0.kind == "CARD" }!)!
        guard case .equation(let law) = newton.content, law.layout != nil else { preconditionFailure("the prompt's equation example typesets") }
        check(law.terms.map(\.id) == ["F", "m", "a"] && newton.elements == [.title, .value, .node("F"), .node("m"), .node("a")],
              "parts are revealed left to right after what belongs to none (the = sign)")
        let offsets = newton.revealOffsets(in: split.spoken, nextCardOffset: nil)
        let spoken = split.spoken as NSString
        check(offsets[2] == spoken.range(of: "force").location && offsets[3] == spoken.range(of: "mass").location
              && offsets[4] == spoken.range(of: "acceleration").location, "each part appears on its own words: \(offsets) in \(split.spoken)")
        let auto = CookieCard.read(#"{"kind":"equation","title":"Energy","tex":"E = mc^2"}"#).card!
        guard case .equation(let energy) = auto.content else { preconditionFailure() }
        check(energy.terms.map(\.id) == ["t1", "t2"] && energy.terms[1].words == "equals m c squared" && auto.nodes.count == 2,
              "with no ids, each side of the = is a part of its own")

        // MARK: Highlight and morph
        check(CookieVisualCommand(body: "highlight:M") == .highlight("m") && CookieVisualCommand(body: "highlight:") == nil, "[VISUAL:highlight:id] names a part")
        check(!CookieScenePresenter().apply(.highlight("m")), "highlighting is never a 3D model's")
        let presenter = CookieCardPresenter()
        presenter.showNow(newton, near: nil)
        check(presenter.apply(.highlight("m")) && presenter.teachingContext?.contains("Selected: m") == true && presenter.focus("a")
              && presenter.teachingContext?.contains("a=acceleration") == true, "a part lights on a beat, and follow-ups know which")
        presenter.dismiss()
        let working = CookieCard.read(#"{"kind":"equation","title":"Solve for a","tex":"\\id{F}{F} = \\id{m}{m}\\id{a}{a}","states":[{},{"at":"divide both sides","tex":"\\id{a}{a} = \\frac{\\id{F}{F}}{\\id{m}{m}}","highlight":"a"}]}"#)
        guard let steps = working.card, case .equation(let before) = steps.states[0], case .equation(let after) = steps.states[1] else {
            preconditionFailure("an equation morphs between lines of working: \(working.errors)")
        }
        let keys = { (eq: CookieCard.Equation) in Set(eq.layout!.pieces.filter { $0.term != nil }.map(\.key)) }
        check(steps.states.count == 2 && keys(before) == keys(after) && after.highlight == "a",
              "the same parts carry the same keys from one line to the next, so they slide instead of fading")
        check(glyphs(after.layout!, "F")[0].origin.y < 0 && glyphs(before.layout!, "F")[0].origin.y == 0, "and they really move (F rises into the numerator)")

        // MARK: build_visual
        CookieVisualBuilder.beginTurn()
        let built = CookieVisualBuilder.build(#"{"kind":"equation","title":"The quadratic formula","tex":"x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}"}"#, id: "quad")
        check(built.ok && built.layout?.contains("Equation typeset") == true && built.layout?.contains("pt card") == true
              && built.layout?.contains("read as \"x equals") == true, "build_visual typesets, renders and reports the equation: \(built.layout ?? "")")

        let bigger = CookieCard.read(#"{"kind":"equation","title":"Gauss's sum","tex":"\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}","caption":"add the first n numbers"}"#).card!
        let calculus = CookieCard.read(#"{"kind":"equation","title":"Area under a curve","tex":"\\int_0^1 x^2\\,dx = \\left[\\frac{x^3}{3}\\right]_0^1 = \\frac{1}{3}"}"#).card!
        let rotation = CookieCard.read(#"{"kind":"equation","title":"A rotation","tex":"R = \\begin{bmatrix} \\cos\\theta & -\\sin\\theta \\\\ \\sin\\theta & \\cos\\theta \\end{bmatrix}"}"#).card!
        CookiePaperTests.render([("equation-quadratic", CookieBuiltVisuals.card("quad")!, 0), ("equation-newton", newton, 0), ("equation-sum", bigger, 0),
                                 ("equation-integral", calculus, 0), ("equation-matrix", rotation, 0), ("equation-plain", unknown.card!, 0),
                                 ("equation-solve-1", steps, 0), ("equation-solve-2", steps, 1)])
        print("\(count) equation checks passed.")
    }
}
