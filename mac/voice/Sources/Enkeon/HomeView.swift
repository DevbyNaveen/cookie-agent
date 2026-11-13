import AppKit
import EnkeonVoiceKit
import SwiftUI

/// Home: a living hero (the voice orb answers the microphone; setup is three steps on a ring), the
/// numbers with motion, then the words themselves — live while you talk, a practice field before the
/// first dictation, a timeline after — beside the chart, the apps and your memory. All real data.
struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    var openDictionary: () -> Void = {}

    private let gap: CGFloat = 6

    var body: some View {
        VStack(spacing: gap) {
            HomeHero().rise(0).brandLift(delay: 0.04)
            metrics.rise(0.05).brandLift(delay: 0.10)
            GeometryReader { space in
                let wide = space.size.width >= 940
                HStack(alignment: .top, spacing: gap) {
                    words.frame(maxWidth: .infinity, maxHeight: .infinity).rise(0.1).brandLift(delay: 0.14)
                    VStack(spacing: gap) {
                        LiveCard()
                        DayChart(values: model.history.wordsPerDay())
                        AppRing(apps: model.history.topApps(limit: 6)).frame(maxHeight: .infinity)
                        if !wide { MemoryCard() }
                    }
                    .frame(width: 300)
                    .rise(0.15)
                    .brandLift(delay: 0.20)
                    if wide {
                        VStack(spacing: gap) {
                            MemoryCard()
                            commands
                            vocabulary.frame(maxHeight: .infinity)
                        }
                        .frame(width: 260)
                        .rise(0.2)
                        .brandLift(delay: 0.25)
                    }
                }
                .frame(width: space.size.width, height: space.size.height, alignment: .top)
            }
        }
        .frame(maxWidth: 1240, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Numbers

    private var metrics: some View {
        HStack(spacing: gap) {
            MetricTile(label: "Words", value: model.history.totalWords, detail: "dictated") {
                Sparkline(values: model.history.wordsPerDay()).frame(height: 22)
            }
            MetricTile(label: "Dictations", value: model.history.records.filter { $0.outcome != .undone }.count, detail: "kept on this Mac") {
                Sparkline(values: model.history.dictationsPerDay(), color: Theme.live).frame(height: 22)
            }
            MetricTile(label: "Pace", value: model.history.wordsPerMinute ?? 0, detail: "words per minute", empty: model.history.wordsPerMinute == nil) {
                PaceGauge(wpm: model.history.wordsPerMinute ?? 0).frame(height: 22)
            }
            MetricTile(label: "Streak", value: model.history.dayStreak, detail: model.history.dayStreak == 1 ? "day" : "days") {
                StreakDots(days: model.history.activeDays()).frame(height: 22)
            }
        }
    }

    // MARK: Your words: practice first, then the timeline

    @ViewBuilder private var words: some View {
        if model.history.records.isEmpty { PracticeCard() } else { Timeline() }
    }

    // MARK: Spoken commands and vocabulary

    private var commands: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHead("Say it while dictating")
            ForEach([("new line", "new line"), ("new paragraph", "blank line"),
                     ("scratch that", "undo"), ("literal …", "as said")], id: \.0) { phrase, effect in
                HStack(spacing: 8) {
                    Text("“\(phrase)”").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                    Spacer(minLength: 8)
                    Text(effect).font(.system(size: 12)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .hoverLift()
    }

    private var vocabulary: some View {
        PanelCard(title: "Your vocabulary") {
            Button("Edit", action: openDictionary)
                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
        } content: {
            if model.vocabularyTerms.isEmpty {
                Text("Names and terms you add are always spelled right.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            } else {
                Chips(tags: model.vocabularyTerms)
            }
        }
    }
}

// MARK: - Hero

/// The greeting on Enkeon's atmosphere, the voice orb, and setup as three steps on a ring.
private struct HomeHero: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.brandPulse) private var brandPulse
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(partOfDay).foregroundStyle(.white.opacity(0.7))
                (Text("\(firstName), say it ") + Text("once").italic() + Text("."))
                    .font(.system(size: 34, weight: .regular, design: .serif))
                    .tracking(-0.7)
                    .foregroundStyle(.white)
                Text(subtitle).font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.82))
                if model.isSetUp {
                    HStack(spacing: 6) {
                        Text("Hold").foregroundStyle(.white.opacity(0.8))
                        HeroKey(model.fnKeyIsFree ? "fn" : "⌃ ⌘")
                        Text("anywhere, or add").foregroundStyle(.white.opacity(0.8))
                        HeroKey("⇧")
                        Text("to save it to memory.").foregroundStyle(.white.opacity(0.8))
                    }
                    .font(.system(size: 13))
                    .padding(.top, 2)
                } else {
                    SetupSteps().padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            FluidOrb(energy: isListening ? model.dictation.level : 0)
                .frame(width: 132, height: 132)
                .keyframeAnimator(initialValue: 0.0, trigger: brandPulse) { orb, response in
                    orb.rotationEffect(.degrees(reduceMotion ? 0 : response * 5))
                        .scaleEffect(reduceMotion ? 1 : 1 + response * 0.025)
                } keyframes: { _ in
                    LinearKeyframe(0, duration: 0.18)
                    CubicKeyframe(1, duration: 0.2)
                    SpringKeyframe(0, duration: 0.4, spring: .smooth)
                }
                .scaleEffect(isListening ? 1 + min(0.08, model.dictation.level * 0.12) : 1)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
                .animation(.easeOut(duration: 0.12), value: model.dictation.level)
                .padding(.trailing, 12)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { Atmosphere() }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var isListening: Bool {
        if case .listening = model.dictation.phase { return true }
        return false
    }

    private var subtitle: String {
        switch model.dictation.phase {
        case .listening: return model.dictation.isMicrophoneReady ? "Listening…" : "Starting microphone…"
        case .finishing: return "Writing it out…"
        default: return model.isSetUp ? "Your words, spelled your way, in any app — and remembered by every AI you use."
                                      : "Three steps and your voice works in every app on this Mac."
        }
    }

    private var partOfDay: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var firstName: String { NSFullUserName().split(separator: " ").first.map(String.init) ?? "Hi" }
}

private struct HeroKey: View {
    let label: String
    init(_ label: String) { self.label = label }
    var body: some View {
        Text(label).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            .padding(.horizontal, 7).frame(height: 22)
            .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Setup as three steps with a ring that fills as each is done.
private struct SetupSteps: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let steps: [(String, Bool)] = [("Allow access", model.permissions.allAllowed),
                                       ("Speech model", model.speechModelReady != false),
                                       ("First dictation", !model.history.records.isEmpty || !model.practiceText.isEmpty)]
        let done = steps.filter(\.1).count
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(.white.opacity(0.18), lineWidth: 4)
                Circle().trim(from: 0, to: CGFloat(done) / 3)
                    .stroke(Theme.live, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(Theme.settle, value: done)
                Text("\(done)/3").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)
            ForEach(steps, id: \.0) { title, ok in
                HStack(spacing: 5) {
                    PhosphorIcon(name: ok ? "CheckCircle" : "Clock", weight: ok ? .fill : .regular, size: 14)
                        .foregroundStyle(ok ? Theme.live : .white.opacity(0.6))
                    Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(ok ? 0.95 : 0.7))
                }
            }
            Button("Finish setup") { model.showOnboarding = true }.buttonStyle(HeroButton())
        }
    }
}

// MARK: - Metric tiles

private struct MetricTile<Accessory: View>: View {
    let label: String
    let value: Int
    let detail: String
    var empty = false
    @ViewBuilder var accessory: Accessory
    @State private var shown = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(label)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(empty ? "—" : shown.formatted())
                    .font(.system(size: 24, weight: .semibold)).tracking(-0.8).monospacedDigit()
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText(value: Double(shown)))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            accessory
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .hoverLift()
        .onAppear { withAnimation(.easeOut(duration: 0.9).delay(0.15)) { shown = value } }
        .onChange(of: value) { _, new in withAnimation(Theme.settle) { shown = new } }
    }
}

/// Pace as a bar: 0 to 200 words a minute (people speak about 130–160).
private struct PaceGauge: View {
    let wpm: Int
    @State private var drawn: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let fraction = min(1, CGFloat(wpm) / 200)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.text.opacity(0.07)).frame(height: 6)
                Capsule().fill(LinearGradient(colors: [Theme.accent.opacity(0.6), Theme.accent], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geometry.size.width * fraction * drawn), height: 6)
            }
            .frame(maxHeight: .infinity)
        }
        .onAppear { withAnimation(Theme.settle.delay(0.2)) { drawn = 1 } }
        .accessibilityLabel("\(wpm) words per minute")
    }
}

/// The last seven days, a dot each, lit when you dictated.
private struct StreakDots: View {
    let days: [Bool]
    @State private var lit = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(days.indices, id: \.self) { index in
                Circle()
                    .fill(days[index] && lit ? Theme.live : Theme.text.opacity(0.1))
                    .frame(width: 10, height: 10)
                    .scaleEffect(days[index] && lit ? 1 : 0.85)
                    .animation(Theme.settle.delay(Double(index) * 0.05), value: lit)
            }
        }
        .frame(maxHeight: .infinity)
        .onAppear { lit = true }
        .accessibilityLabel("\(days.filter { $0 }.count) of the last \(days.count) days")
    }
}

// MARK: - Live words

/// What you're saying right now, word by word, over the microphone's waveform.
private struct LiveCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHead(title: "Right now") { LiveBadge(label: label, live: model.isSetUp) }
            Text(text)
                .font(.system(size: 14, weight: isLive ? .medium : .regular))
                .foregroundStyle(isLive ? Theme.text : Theme.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
                .contentTransition(.interpolate)
                .animation(.easeOut(duration: 0.12), value: model.dictation.liveText)
            ListeningWave(active: isLive, levels: model.dictation.levels).frame(height: 22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .hoverLift()
    }

    private var isLive: Bool {
        if case .listening = model.dictation.phase { return true }
        return false
    }

    private var label: String {
        switch model.dictation.phase {
        case .listening: return model.dictation.isMicrophoneReady ? "listening" : "starting"
        case .finishing: return "writing"
        default: return model.isSetUp ? "ready" : "setup"
        }
    }

    private var text: String {
        switch model.dictation.phase {
        case .listening: return model.dictation.isMicrophoneReady ? (model.dictation.liveText.isEmpty ? "Listening…" : model.dictation.liveText) : "Starting microphone…"
        case .finishing: return model.dictation.liveText.isEmpty ? "Writing it out…" : model.dictation.liveText
        case .done(let message, _): return message
        case .idle: return "Hold \(model.fnKeyIsFree ? "fn" : "⌃⌘") in any app and your words appear here as you say them."
        }
    }
}

private struct ListeningWave: View {
    let active: Bool
    let levels: [CGFloat]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let count = 48
                let recent = Array(levels.suffix(count))
                let step = size.width / CGFloat(count - 1)
                var path = Path()
                for index in 0..<count {
                    let x = CGFloat(index) * step
                    let idle = sin(time * 1.4 + Double(index) * 0.28) * 0.12
                    let level = active && index < recent.count ? Double(recent[index]) : 0
                    let amplitude = active ? max(0.08, level * 1.4) : 0.6
                    let y = size.height / 2 + CGFloat((active ? sin(Double(index) * 0.9 + time * 9) * amplitude : idle * amplitude)) * size.height / 2
                    index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                }
                canvas.stroke(path, with: .linearGradient(
                    Gradient(colors: [Theme.brand.opacity(0.15), active ? Theme.live : Theme.brand, Theme.brand.opacity(0.15)]),
                    startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)), lineWidth: 1.5)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Before the first dictation: a field on Home to try it, right here.
private struct PracticeCard: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHead(title: "Try it here") {
                if !model.practiceText.isEmpty {
                    Button("Clear") { model.practiceText = "" }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                }
            }
            HStack(spacing: 6) {
                Text("Click the box, hold").foregroundStyle(Theme.secondary)
                DictationKeys()
                Text("and say anything.").foregroundStyle(Theme.secondary)
            }
            .font(.system(size: 12))
            TextEditor(text: $model.practiceText)
                .focused($focused)
                .font(.system(size: 16))
                .scrollContentBackground(.hidden)
                .padding(14)
                .frame(maxHeight: .infinity)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(focused ? Theme.accent : .clear, lineWidth: focused ? 2 : 1))
                .overlay(alignment: .topLeading) {
                    if model.practiceText.isEmpty {
                        Text("Your words land here…").font(.system(size: 16)).foregroundStyle(Theme.tertiary)
                            .padding(.horizontal, 19).padding(.vertical, 14).allowsHitTesting(false)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: focused)
            Text("Once you've dictated anywhere, this becomes your timeline.").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

// MARK: - Timeline

private struct Timeline: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PanelCard(title: "Recent dictations") {
            Text("\(model.history.records.count)").font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(Theme.tertiary)
        } content: {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(model.history.records.prefix(200)) { record in
                    TimelineRow(record: record)
                        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                }
            }
            .animation(Theme.settle, value: model.history.records.first?.id)
        }
    }
}

private struct TimelineRow: View {
    @EnvironmentObject private var model: AppModel
    let record: DictationRecord
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // What happened to it, not where: typed, saved to memory, kept, or undone.
            PhosphorIcon(name: glyph, size: 14)
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(record.text.isEmpty ? "—" : record.text)
                    .font(.system(size: 13))
                    .foregroundStyle(record.outcome == .undone ? Theme.tertiary : Theme.text)
                    .strikethrough(record.outcome == .undone)
                    .lineLimit(3)
                    .textSelection(.enabled)
                HStack(spacing: 5) {
                    Text(record.app)
                    Text("·")
                    Text(record.date, format: .relative(presentation: .named))
                    if record.outcome == .remembered { Text("·"); Text("saved to memory").foregroundStyle(Theme.accent) }
                    if record.outcome == .kept { Text("·"); Text("kept here").foregroundStyle(Theme.warning) }
                }
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if hovering {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.text, forType: .string)
                } label: { PhosphorIcon(name: "Copy", size: 14).foregroundStyle(Theme.secondary) }
                    .buttonStyle(.plain).help("Copy")
                Button { model.history.delete(record) } label: { PhosphorIcon(name: "Trash", size: 14).foregroundStyle(Theme.secondary) }
                    .buttonStyle(.plain).help("Delete")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.text.opacity(hovering ? 0.04 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var glyph: String {
        switch record.outcome {
        case .remembered: return "Brain"
        case .kept: return "Copy"
        case .undone: return "ArrowUUpLeft"
        default: return "Microphone"
        }
    }

    private var tint: Color {
        switch record.outcome {
        case .remembered: return Color(hex: 0xE0A458)
        case .kept: return Theme.warning
        case .undone: return Theme.tertiary
        default: return Theme.accent
        }
    }
}

// MARK: - Chart

/// Words per day: bars rise one after another, today glows, a hover shows the count.
private struct DayChart: View {
    let values: [Double]
    @State private var risen = false
    @State private var hovered: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHead(title: "Last 14 days") {
                Text(hovered.map { "\(Int(values[$0])) words" } ?? "\(Int(values.reduce(0, +)).formatted()) words")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(Theme.tertiary)
                    .contentTransition(.numericText())
            }
            let top = max(values.max() ?? 0, 1)
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(values.indices, id: \.self) { index in
                    let today = index == values.count - 1
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(values[index] > 0
                              ? AnyShapeStyle(LinearGradient(colors: today ? [Theme.live, Theme.live.opacity(0.6)] : [Theme.accent, Theme.accent.opacity(0.45)],
                                                             startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle(Theme.text.opacity(0.07)))
                        .frame(height: max(4, (risen ? values[index] / top : 0) * 54))
                        .frame(maxWidth: .infinity, maxHeight: 54, alignment: .bottom)
                        .shadow(color: today && values[index] > 0 ? Theme.live.opacity(0.5) : .clear, radius: 6)
                        .opacity(hovered == nil || hovered == index ? 1 : 0.45)
                        .animation(Theme.settle.delay(Double(index) * 0.03), value: risen)
                        .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
                }
            }
            .frame(height: 54)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .hoverLift()
        .onAppear { risen = true }
    }
}

// MARK: - Apps ring

/// Where you dictate: a ring that draws in, a segment per app, its color in the legend.
private struct AppRing: View {
    let apps: [(app: String, count: Int, bundleID: String?)]
    @State private var drawn: CGFloat = 0
    private let palette = [Theme.accent, Theme.live, Color(hex: 0xE0A458), Color(hex: 0xB48EE0), Color(hex: 0xE07A7A), Color(hex: 0x8AA0B4)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHead("Where you dictate")
            if apps.isEmpty {
                Text("The apps you dictate into, and how much, show up here.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
            } else {
                let total = Double(apps.reduce(0) { $0 + $1.count })
                HStack(alignment: .center, spacing: 14) {
                    ZStack {
                        ForEach(apps.indices, id: \.self) { index in
                            let start = apps.prefix(index).reduce(0.0) { $0 + Double($1.count) } / total
                            let end = start + Double(apps[index].count) / total
                            Circle().trim(from: start * drawn, to: end * drawn)
                                .stroke(palette[index % palette.count], style: StrokeStyle(lineWidth: 10, lineCap: .butt))
                                .rotationEffect(.degrees(-90))
                        }
                        Text("\(Int(total))").font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text)
                    }
                    .frame(width: 74, height: 74)
                    // A long app list scrolls inside the card instead of stretching it.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(apps.indices, id: \.self) { index in
                                HStack(spacing: 7) {
                                    Circle().fill(palette[index % palette.count]).frame(width: 8, height: 8)
                                    Text(apps[index].app).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text("\(apps[index].count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.tertiary)
                                }
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                    .frame(minHeight: 74)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .hoverLift()
        .onAppear { withAnimation(.easeOut(duration: 1.0).delay(0.2)) { drawn = 1 } }
    }
}

// MARK: - Memory

/// What Enkeon knows for you — the part no other dictation app has.
private struct MemoryCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHead(title: "Your memory") {
                LiveBadge(label: model.account.isSignedIn ? "connected" : "not connected", live: model.account.isSignedIn)
            }
            if model.account.isSignedIn {
                fact("Brain", "\(model.enkeonTerms.count)", "projects spelled right")
                fact("BookOpenText", "\(model.vocabularyTerms.count + model.learned.count)", "words you taught it")
                fact("NotePencil", "\(model.history.notesThisWeek)", "notes saved this week")
            } else {
                Text("Connect Enkeon and dictation knows your projects and people, and ⇧ saves what you say for every AI you use.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Button("Connect") { model.page = .connections }.buttonStyle(PrimaryButton())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .hoverLift()
    }

    private func fact(_ icon: String, _ value: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            PhosphorIcon(name: icon, size: 15).foregroundStyle(Theme.accent).frame(width: 18)
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text)
                .contentTransition(.numericText())
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
        }
    }
}

// MARK: - Motion

private struct Rise: ViewModifier {
    let delay: Double
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .onAppear { withAnimation(Theme.settle.delay(delay)) { shown = true } }
    }
}

private struct HoverLift: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.008 : 1)
            .shadow(color: .black.opacity(hovering ? 0.18 : 0), radius: hovering ? 12 : 0, y: hovering ? 4 : 0)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.18), value: hovering)
    }
}

extension View {
    /// Fades and rises in when the page opens, after `delay` seconds.
    func rise(_ delay: Double) -> some View { modifier(Rise(delay: delay)) }
    /// Lifts a little under the pointer.
    func hoverLift() -> some View { modifier(HoverLift()) }
}
