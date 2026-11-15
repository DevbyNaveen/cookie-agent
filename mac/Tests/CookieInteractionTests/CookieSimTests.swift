import AppKit
import SwiftUI

/// Sim cards: every model checked against the physics it claims (closed forms and textbook
/// results), stable at every corner of its parameter ranges, read forgivingly, driven by beats and
/// [VISUAL:…] verbs, paused when hidden, and the prompt's own example.
@MainActor
enum CookieSimTests {
    static func run() {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            count += 1
        }
        func close(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool { abs(a - b) <= tolerance * max(1e-12, abs(b)) }

        // MARK: Pendulum: the small-angle period, and the exact one at large angles
        func measuredPeriod(_ angle: Double, length: Double = 1, g: Double = 9.81) -> Double {
            var pendulum = Pendulum(["length": length, "gravity": g, "angle": angle], [:])
            let h = 1.0 / 2000
            var crossings: [Double] = []
            var previous = pendulum.y[0]
            while crossings.count < 3, pendulum.time < 60 {
                pendulum.advance(by: h)
                let now = pendulum.y[0]
                if previous > 0, now <= 0 { crossings.append(pendulum.time - h * now / (now - previous)) }
                previous = now
            }
            return crossings[2] - crossings[1]
        }
        let small = Pendulum(["length": 1, "gravity": 9.81, "angle": 2], [:])
        check(close(small.smallAnglePeriod, 2 * .pi * (1 / 9.81).squareRoot(), 1e-12) && close(measuredPeriod(2), small.smallAnglePeriod, 1e-3),
              "a small swing takes 2π√(L/g)")
        let wide = Pendulum(["length": 1, "gravity": 9.81, "angle": 60], [:])
        check(close(measuredPeriod(60), wide.period, 5e-4) && close(wide.period / wide.smallAnglePeriod, 1.07318, 1e-4),
              "a wide swing is slower, as the exact period says (7.3% at 60°)")

        // MARK: Projectile: range and height without drag, shorter with it
        let throwBall = Projectile(["speed": 20, "angle": 30, "gravity": 9.81, "drag": 0], [:])
        let angle = 30 * Double.pi / 180
        check(close(throwBall.range, 400 * sin(2 * angle) / 9.81, 1e-4) && close(throwBall.height, 400 * pow(sin(angle), 2) / (2 * 9.81), 1e-4)
              && close(throwBall.flight, 2 * 20 * sin(angle) / 9.81, 1e-4), "without drag: R = v²sin2θ/g, H = v²sin²θ/2g")
        let dragged = Projectile(["speed": 20, "angle": 30, "gravity": 9.81, "drag": 0.05], [:])
        check(dragged.range < throwBall.range * 0.9 && dragged.readouts().contains { $0.id == "drag_free_range" }, "drag shortens the flight, and says by how much")

        // MARK: Spring: the damped solution, and energy
        let (m, k, c, x0) = (1.0, 20.0, 0.4, 0.2)
        var spring = Spring(["mass": m, "stiffness": k, "damping": c, "pull": x0], [:])
        spring.advance(by: 3)
        let gamma = c / (2 * m), wd = (k / m - gamma * gamma).squareRoot(), t = spring.time
        let exact = exp(-gamma * t) * (x0 * cos(wd * t) + gamma * x0 / wd * sin(wd * t))
        let exactV = exp(-gamma * t) * ((gamma * x0 / wd * wd - gamma * x0) * cos(wd * t) - (x0 * wd + gamma * gamma * x0 / wd) * sin(wd * t))
        check(abs(spring.y[0] - exact) < 1e-6 && abs(spring.y[1] - exactV) < 1e-5, "the spring follows x(t) = x₀e^(−γt)(cos ω_d t + γ/ω_d sin ω_d t)")
        check(close(spring.energy, 0.5 * k * exact * exact + 0.5 * m * exactV * exactV, 1e-4) && spring.energy < 0.5 * k * x0 * x0 * 0.4,
              "damping drains its energy at the exact rate")
        var free = Spring(["mass": 0.1, "stiffness": 100, "damping": 0, "pull": 0.3], [:])
        free.advance(by: 10)
        check(close(free.energy, 0.5 * 100 * 0.09, 1e-6) && close(free.period!, 2 * .pi * (0.1 / 100).squareRoot(), 1e-12),
              "undamped, energy is kept to a millionth over ten seconds at the stiffest setting")
        check(Spring(["mass": 0.1, "stiffness": 1, "damping": 5, "pull": 0.2], [:]).period == nil, "an overdamped spring has no period, and says so")

        // MARK: Orbit
        var earth = Orbit(["gravity": 4 * .pi * .pi, "speed": 2 * .pi], [:])
        check(close(earth.period!, 1, 1e-12), "a circular orbit at 1 AU with GM = 4π² takes a year")
        let start = earth.p
        earth.advance(by: 1)
        let energy = { (o: Orbit) in (o.v * o.v).sum() / 2 - o.gm / (o.p * o.p).sum().squareRoot() }
        check(((earth.p - start) * (earth.p - start)).sum().squareRoot() < 2e-3 && close(energy(earth), 2 * .pi * .pi - 4 * .pi * .pi, 1e-6),
              "after a year it is back where it began, its energy kept")
        check(Orbit(["gravity": 10, "speed": 12], [:]).period == nil, "too fast to hold: no period, it escapes")

        // MARK: Decay
        var atoms = Decay(["halflife": 2, "atoms": 10_000], [:])
        check(atoms.left(at: 0) == 10_000 && atoms.expected(at: 2) == 5000, "N₀·2^(−t/T½): half at one half-life")
        atoms.advance(by: 2)
        check(close(Double(atoms.left(at: 2)), 5000, 0.03) && close(Double(atoms.left(at: 4)), 2500, 0.05), "random atoms follow the half-life (\(atoms.left(at: 2)) of 10000)")
        check(Decay(["halflife": 2, "atoms": 100], [:]).lifetimes == Decay(["halflife": 2, "atoms": 100], [:]).lifetimes, "the same decay plays the same way each time")

        // MARK: Queue (M/M/1)
        var queue = Queue(["arrivals": 2, "service": 3], [:])
        for _ in 0..<100 { queue.advance(by: 1000) }
        check(queue.served > 150_000 && close(queue.meanWait!, 2.0 / 3.0, 0.05) && close(queue.expectedWait!, 2.0 / 3.0, 1e-12),
              "the mean wait in line settles on λ/(μ(μ−λ)): \(queue.meanWait!) over \(queue.served) people")
        check(Queue(["arrivals": 5, "service": 3], [:]).readouts().contains { $0.text == "grows without limit" }, "when people come faster than they're served, it says the line grows")

        // MARK: Wave
        let wave = Wave(["frequency": 2, "amplitude": 3, "speed": 1, "sources": 2, "separation": 1.5], [:])
        var playing = wave
        playing.advance(by: 20)
        let lambda = wave.wavelength
        check(close(lambda, 0.5, 1e-12) && wave.loudLines == 5, "λ = v/f, and the loud lines are every n with |n|λ < d")
        let loud = playing.sum(4, 4 - lambda), quiet = playing.sum(4, 4 - lambda / 2), one = playing.sum(4, 100) // the second hasn't arrived from 100 m
        check(abs(loud - 2 * one) < 1e-9 && abs(quiet) < 1e-9, "a path difference of λ doubles the wave, of λ/2 cancels it")

        // MARK: Flow
        var pipe = Flow(["speed": 1, "wide": 10, "narrow": 5], [:])
        check(close(pipe.v2, 4, 1e-12) && close(pipe.pressureDrop, 0.5 * 1000 * (16 - 1), 1e-12), "v₂ = v₁(D₁/D₂)² and Δp = ½ρ(v₂² − v₁²)")
        pipe.tracers = [(0.4, 0)]
        let entered = pipe.time
        while pipe.tracers[0].x < 0.6 { pipe.advance(by: pipe.h) }
        check(close(pipe.time - entered, 0.2 / 4, 0.02), "a tracer crosses the narrow part at the narrow speed")

        // MARK: Growth
        let money = Growth(["rate": 5, "compounding": 12, "start": 1000, "years": 10], [:])
        var stepped = 1000.0
        for _ in 0..<120 { stepped *= 1 + 0.05 / 12 }
        check(close(money.balance(at: 10), stepped, 1e-12) && close(money.balance(at: 10), 1000 * pow(1 + 0.05 / 12, 120), 1e-12),
              "compounding monthly is P(1 + r/n)^(nt), step by step")
        check(close(money.doublingTime, log(2) / (12 * log(1 + 0.05 / 12)), 1e-12)
              && close(Growth(["rate": 5, "compounding": 0, "start": 1, "years": 10], [:]).balance(at: 10), exp(0.5), 1e-12),
              "its doubling time, and continuous growth e^(rt)")

        // MARK: Stable everywhere it can be set
        for model in CookieSim.models.values {
            var corners: [[String: Double]] = [model.defaults]
            for param in model.params {
                corners = corners.flatMap { setting in [param.range.lowerBound, param.range.upperBound].map { var next = setting; next[param.id] = $0; return next } }
            }
            for corner in corners {
                var simulation = model.make(corner, [:])
                for _ in 0..<120 { simulation.advance(by: simulation.playback / 60) }
                let finite = simulation.readouts().allSatisfy { $0.value?.isFinite ?? true } && simulation.draw(in: CookieSim.canvas).isFinite
                check(finite, "\(model.id) stays finite at \(corner)")
                var still = model.make(corner, [:])
                still.representative()
                check(still.draw(in: CookieSim.canvas).isFinite, "\(model.id)'s still frame is finite at \(corner)")
            }
        }

        // MARK: Reading
        let read = CookieCard.read(#"{"kind":"simulation","title":"A spring","model":"oscillator","params":{"k":500,"m":"2","colour":3},"sliders":["damping",{"param":"mass","minimum":0,"maximum":9},"nope"],"running":"paused"}"#)
        guard case .sim(let springCard)? = read.card?.content else { preconditionFailure("a sim reads forgivingly: \(read.errors)") }
        check(springCard.model == "spring" && springCard.values["stiffness"] == 100 && springCard.values["mass"] == 2 && !springCard.running
              && springCard.sliders.map(\.param) == ["damping", "mass"] && springCard.sliders[1].minimum == 0.1 && springCard.sliders[1].maximum == 5,
              "aliases, numbers in range, sliders inside the safe range")
        check(["kind: read \"simulation\"", "model: read \"oscillator\"", "params.k: read as stiffness", "params.k: brought inside", "params.colour: spring has no such parameter",
               "sliders[1]: kept inside", "sliders[2]: spring has no parameter", "running: read \"paused\""].allSatisfy { want in read.repairs.contains { $0.contains(want) } },
              "every repair is said: \(read.repairs)")
        check(CookieCard.read(#"{"kind":"sim","title":"T","model":"tornado"}"#).errors.first?.contains("isn't in the library") == true, "a model outside the library is refused, naming the ones there are")

        // MARK: The prompt's example, on the speech clock
        let prompt = CompanionManager.companionVoiceResponseSystemPrompt
        let line = prompt.components(separatedBy: "\n").first { $0.contains("one pendulum, two worlds") }!
        let example = line.components(separatedBy: "and: \"")[1].components(separatedBy: "\" or \"")[0]
        let split = CookieReplyTags.split(example)
        let moon = CookieCard(tag: split.tags.first { $0.kind == "CARD" }!)!
        guard case .sim(let earthState) = moon.states[0], case .sim(let moonState) = moon.states[1] else { preconditionFailure("the prompt's sim example has two states") }
        check(moonState.values["gravity"] == 1.62 && moonState.values["length"] == 1 && moonState.values["angle"] == 15 && earthState.values["gravity"] == 9.81,
              "a state changes only the params it names")
        let cue = moon.stateOffsets(in: split.spoken, after: moon.offset).offsets
        check(cue == [(split.spoken as NSString).range(of: "on the moon", options: [], range: NSRange(location: moon.offset, length: (split.spoken as NSString).length - moon.offset)).location],
              "the moon arrives on its words")
        let reveal = CookieCardReveal(card: moon)
        let earthPeriod = reveal.sim!.readouts.first { $0.id == "period" }!.value!
        reveal.show(state: 1)
        let moonPeriod = reveal.sim!.readouts.first { $0.id == "period" }!.value!
        check(abs(earthPeriod - 2.01) < 0.01 && abs(moonPeriod - 4.96) < 0.01, "what the example says is what the sim reads: \(earthPeriod) s, then \(moonPeriod) s")

        // MARK: Beats and verbs
        check(CookieVisualCommand(body: "run") == .run && CookieVisualCommand(body: "pause") == .pause
              && CookieVisualCommand(body: "set:Gravity:1.62") == .set(parameter: "gravity", value: 1.62)
              && CookieVisualCommand(body: "set:gravity:fast") == nil && CookieVisualCommand(body: "set:gravity") == nil, "[VISUAL:run|pause|set:param:value]")
        let scenes = CookieScenePresenter()
        check(!scenes.apply(.run) && !scenes.apply(.set(parameter: "gravity", value: 2)), "sim verbs are never a 3D model's")
        let presenter = CookieCardPresenter()
        presenter.showNow(moon, near: nil)
        check(presenter.apply(.set(parameter: "gravity", value: 1.62)) && presenter.teachingContext?.contains("period " + CookieCard.format(4.96) + " s") == true
              && presenter.teachingContext?.contains("[VISUAL:set:<parameter>:<value>]") == true, "set reaches the sim on screen, and follow-ups see the new values: \(presenter.teachingContext ?? "nil")")
        check(presenter.apply(.set(parameter: "gravity", value: 99)) && presenter.teachingContext?.contains("gravity = 25 m/s²") == true,
              "a value past the safe range is kept inside it")
        check(!presenter.apply(.set(parameter: "colour", value: 1)), "a parameter the model hasn't is refused")
        check(presenter.apply(.pause) && presenter.teachingContext?.contains("Paused") == true && presenter.apply(.run), "run and pause")
        presenter.dismiss()

        // MARK: Runs only when it can be seen
        let runner = CookieSimRunner(moonState)
        check(runner.simulation.time > 0, "before it is live (Reduce Motion, off-screen renders) it holds a representative frame with its trail")
        runner.live = true
        check(runner.simulation.time == 0 && !runner.ticking, "going live starts from the first moment, but not before it is revealed")
        runner.shown = true
        check(runner.ticking, "revealed and live, it runs on the display link")
        let folding = CookieCardReveal(card: moon)
        folding.sim!.live = true
        folding.reveal(through: folding.elements.count - 1, instant: true)
        check(folding.sim!.ticking, "a revealed card's sim runs")
        folding.collapsed = true
        check(!folding.sim!.ticking, "folded, it pauses")
        folding.collapsed = false
        folding.occluded = true
        check(!folding.sim!.ticking, "covered, it pauses")
        folding.occluded = false
        check(folding.sim!.ticking, "and picks up when seen again")
        folding.stop()
        runner.stop()
        check(!folding.sim!.ticking && !runner.ticking, "closed, it stops")

        // MARK: build_visual
        CookieVisualBuilder.beginTurn()
        let built = CookieVisualBuilder.build(#"{"kind":"sim","title":"How far it flies","model":"projectile","params":{"speed":20,"angle":45},"sliders":["angle","drag"]}"#, id: "throw")
        check(built.ok && built.layout?.contains("Values to quote: range " + CookieCard.format(40.8) + " m") == true && built.layout?.contains("pt card") == true,
              "build_visual reports the values the voice may quote: \(built.layout ?? "")")

        func card(_ model: String, _ title: String, _ params: String = "{}", sliders: String = "[]") -> CookieCard {
            CookieCard.read(#"{"kind":"sim","title":"\#(title)","model":"\#(model)","params":\#(params),"sliders":\#(sliders)}"#).card!
        }
        CookiePaperTests.render([
            ("sim-orbit", card("orbit", "An elliptical orbit", #"{"speed":7.5}"#, sliders: #"["speed"]"#), 0),
            ("sim-spring", card("spring", "A damped spring", sliders: #"["damping","stiffness"]"#), 0),
            ("sim-pendulum", moon, 0),
            ("sim-projectile", CookieBuiltVisuals.card("throw")!, 0),
            ("sim-wave", card("wave", "A wave on a rope"), 0),
            ("sim-interference", card("wave", "Two sources interfering", #"{"sources":2,"frequency":1.5}"#, sliders: #"["separation"]"#), 0),
            ("sim-queue", card("queue", "A line at one counter", #"{"arrivals":2.6}"#, sliders: #"["arrivals","service"]"#), 0),
            ("sim-flow", card("flow", "Squeezing a pipe"), 0),
            ("sim-decay", card("decay", "Half-life", sliders: #"["halflife"]"#), 0),
            ("sim-growth", card("growth", "Compound interest", sliders: #"["rate","compounding"]"#), 0),
        ])
        print("\(count) sim checks passed.")
    }
}
