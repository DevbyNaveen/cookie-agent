import SwiftUI

struct AgentDockView: View {
    @ObservedObject var state: CookieDockState
    @ObservedObject private var agents = CookieAgentStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let stop: (DockEntry) -> Void
    let open: (DockEntry) -> Void

    var body: some View {
        let geometry = CookieDockGeometry(availableSize: state.availableSize)
        ScrollView(.vertical) {
            VStack(alignment: .trailing, spacing: 10) {
                ForEach(state.entries) { entry in
                    CookieDockSurface(entry: entry, agent: agents.agent(entry.agentID) ?? agents.agents.first,
                                      geometry: geometry, progress: state.expandedID == entry.id ? 1 : 0,
                                      historyProgress: state.historyID == entry.id ? 1 : 0,
                                      expand: { state.expand(entry.id) }, collapse: state.collapse,
                                      toggleHistory: { state.historyID = state.historyID == entry.id ? nil : entry.id },
                                      stop: { stop(entry) }, open: { open(entry) })
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(CookieDockGeometry.inset)
        }
        .scrollIndicators(.hidden)
        .frame(width: geometry.canvas.width, height: geometry.canvas.height, alignment: .topTrailing)
        .coordinateSpace(name: "cookieDock")
        .onPreferenceChange(CookieDockRegions.self, perform: state.geometryChanged)
        .animation(reduceMotion ? nil : CK.spring, value: state.expandedID)
        .animation(reduceMotion ? nil : CK.spring, value: state.historyID)
        .environment(\.colorScheme, .dark)
        .cookieMotionPreferences()
    }
}

/// The face, graphite and details share one mask at every point in the spring.
/// Fixed-width text prevents paragraphs reflowing as the surface unfolds.
struct CookieDockSurface: View, Animatable {
    let entry: DockEntry
    let agent: CookieAgent?
    let geometry: CookieDockGeometry
    var progress: CGFloat
    var historyProgress: CGFloat
    let expand: () -> Void
    let collapse: () -> Void
    let toggleHistory: () -> Void
    let stop: () -> Void
    let open: () -> Void

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, historyProgress) }
        set { progress = newValue.first; historyProgress = newValue.second }
    }

    private var fraction: CGFloat { min(1, max(0, progress)) }
    private var historyFraction: CGFloat { min(1, max(0, historyProgress)) }
    private var expandedHeight: CGFloat { geometry.cardHeight + geometry.historyHeight * historyFraction }
    private var size: CGSize {
        CGSize(width: CookieDockGeometry.bubbleSize + (geometry.cardWidth - CookieDockGeometry.bubbleSize) * fraction,
               height: CookieDockGeometry.bubbleSize + (expandedHeight - CookieDockGeometry.bubbleSize) * fraction)
    }
    private var mood: ClayCookie.Mood {
        entry.phase == .speaking ? .speaking : entry.phase == .listening ? .listening : .thinking
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CK.island.opacity(fraction)
            details
                .frame(width: max(0, geometry.cardWidth - 28), height: max(0, expandedHeight - 28), alignment: .topLeading)
                .padding(14)
                .opacity(min(1, max(0, (fraction - 0.65) / 0.3)))
                .allowsHitTesting(fraction > 0.95)
                .accessibilityHidden(fraction < 0.95)
            CookieAvatar(size: 44 - 8 * fraction, agent: agent, mood: mood, animatesIdle: true,
                         isEngaged: fraction > 0.5)
                .frame(width: 44 - 8 * fraction, height: 44 - 8 * fraction)
                .offset(x: 4 + 10 * fraction, y: 4 + 12 * fraction)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Button(action: expand) { Color.clear.contentShape(RoundedRectangle(cornerRadius: 22)) }
                .buttonStyle(.plain)
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(fraction < 0.05)
                .accessibilityHidden(fraction >= 0.05)
                .accessibilityLabel("\(agent?.name ?? "Cookie"), \(entry.status). Show details")
                .help("\(agent?.name ?? "Cookie") · \(entry.status)")
                .cookiePointingCursor()
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(GeometryReader { proxy in
            Color.clear.preference(key: CookieDockRegions.self,
                                   value: [entry.id: proxy.frame(in: .named("cookieDock"))])
        })
        .foregroundStyle(CK.text)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Color.clear.frame(width: 36, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(agent?.name ?? "Cookie")
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(entry.status).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CK.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Group {
                    if fraction > 0.05 { CookieVoiceMedallion(phase: entry.phase, audioLevel: 0, size: 24) }
                    else { Color.clear.frame(width: 24, height: 24) }
                }
                IslandButton(symbol: "chevron.right", help: "Collapse details", size: 24, action: collapse)
                    .accessibilityLabel("Collapse details")
            }
            Text(entry.step)
                .font(.system(size: 13)).lineSpacing(3)
                .lineLimit(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityLabel(entry.step)
            history
                .frame(height: geometry.historyHeight * historyFraction)
                .clipped()
                .opacity(historyFraction)
                .accessibilityHidden(historyFraction < 0.95)
                .padding(.top, -12 * (1 - historyFraction))
            HStack(spacing: 4) {
                if !entry.history.isEmpty {
                    Button(action: toggleHistory) {
                        HStack(spacing: 5) {
                            Image(systemName: "list.bullet").font(.system(size: 10, weight: .medium))
                            Text("\(entry.history.count) steps").monospacedDigit()
                        }
                    }
                    .buttonStyle(CookieDockButtonStyle())
                    .accessibilityLabel(historyFraction > 0.5 ? "Hide activity" : "Show activity")
                    .help("Show the steps so far")
                }
                Spacer(minLength: 0)
                Button(action: stop) { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(CookieDockButtonStyle())
                    .accessibilityLabel("Stop \(agent?.name ?? "Cookie")")
                Button(action: open) { Label("Open", systemImage: "arrow.up.right") }
                    .buttonStyle(CookieDockButtonStyle(prominent: true))
                    .accessibilityLabel("Open conversation")
            }
            .frame(height: 30)
        }
    }

    private var history: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(entry.history.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 9) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(CK.tertiary)
                            .frame(width: 14, alignment: .trailing).padding(.top, 2)
                        Text(step).font(.system(size: 11.5)).foregroundStyle(CK.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }
}

private struct CookieDockRegions: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct CookieDockButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration, prominent: prominent)
    }
    private struct Content: View {
        let configuration: Configuration
        let prominent: Bool
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 11.5, weight: .medium))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 9).frame(height: 30)
                .foregroundStyle(prominent ? CK.accent : hovering ? CK.text : CK.secondary)
                .background(prominent ? CK.accent.opacity(hovering ? 0.20 : 0.12) : Color.white.opacity(hovering ? 0.07 : 0),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(configuration.isPressed ? 0.65 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .onHover { hovering = $0 }
                .cookiePointingCursor()
                .animation(CK.quick, value: hovering)
        }
    }
}
