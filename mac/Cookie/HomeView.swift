import AppKit
import EnkeonVoiceKit
import SwiftUI

/// Home, sized for Cookie's console: setup while it isn't done, four numbers, then your words —
/// a practice field before the first dictation, the timeline after. All real data.
struct HomeView: View {
    @EnvironmentObject private var model: AppModel

    private let gap: CGFloat = 6

    var body: some View {
        let summary = model.history.weeklySummary()
        GeometryReader { geometry in
            let compact = CookieWeeklyCardPresentation.isCompact(availableHeight: geometry.size.height)
            VStack(spacing: 10) {
                if !model.isSetUp { SetupSteps().frame(maxWidth: .infinity, alignment: .leading).card() }
                metrics.rise(0.05)
                if summary.dictations > 0 {
                    CookieWeeklyShareCard(summary: summary, compact: compact)
                        .frame(height: compact ? CookieWeeklyCardPresentation.compactHeight : CookieWeeklyCardPresentation.expandedHeight)
                }
                words.frame(maxWidth: .infinity, maxHeight: .infinity).rise(0.1)
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
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
