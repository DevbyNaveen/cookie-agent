import AppKit
import SwiftUI

/// Enkeon on the Mac: Apple's own materials and semantic colors, so it reads right in Light and Dark
/// mode and beside every other Mac app, with one Enkeon color — the Console's brand teal (`--brand`,
/// #4A8FAE) — for selection, charts and actions. The layout stays the Console's: the rail on a
/// translucent sidebar, the workspace floating beside it, borderless cards inside.
enum Theme {
    // Enkeon Voice's pages inside Cookie: every token is Cookie's (CK), so they read as one app.
    static let underlay = Color.clear
    static let background = CK.island
    static let card = CK.fill
    static let surface = CK.fill
    static let raised = CK.fillHover
    static let border = CK.hairline
    static let stroke = CK.hairline
    static let hairline = CK.hairline
    static let text = CK.text
    static let secondary = CK.secondary
    static let tertiary = CK.tertiary
    static let accent = CK.accent
    static let brand = accent
    static let live = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let bar = Color(red: 0.04, green: 0.04, blue: 0.05)
    static let settle = CK.spring

    static let consoleURL = URL(string: "https://www.enkeon.com")!
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// One color for Light mode, another for Dark, resolved by AppKit as the appearance changes.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// The macOS sidebar material (Finder, Notes, Music): translucent, it takes on the desktop behind it.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Frosted glass for floating teaching cards: the desktop shows through, blurred. Always active,
/// because the card's panel never becomes key and an inactive material would go flat grey.
struct CookieGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension View {
    /// A card: Apple's grouped fill, rounded, no border.
    func card(padding: CGFloat = 14) -> some View {
        self.padding(.horizontal, padding).padding(.vertical, 12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Cards sit straight on the workspace: the old board is just their spacing now.
    func board() -> some View { self }
}

/// `.central-home__card-title`, with an optional right-side note.
struct CardHead<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).tracking(-0.12).foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: 20)
    }
}

extension CardHead where Trailing == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

/// `.central-home__k`: 10 px, 600, 0.08 em, uppercase.
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.tertiary)
    }
}

/// The green "live" state: a dot with a soft ring that breathes.
struct LiveBadge: View {
    let label: String
    var live = true
    @State private var breathe = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(live ? Theme.live : Theme.secondary.opacity(0.55))
                .frame(width: 5, height: 5)
                .background(
                    Circle()
                        .fill((live ? Theme.live : .clear).opacity(breathe ? 0.04 : 0.18))
                        .frame(width: breathe ? 13 : 11, height: breathe ? 13 : 11)
                )
            Text(label).font(.system(size: 11, weight: .medium))
                .foregroundStyle(live ? Theme.live : Theme.secondary.opacity(0.74))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background((live ? Theme.live : Theme.secondary).opacity(0.1), in: Capsule())
        .onAppear {
            guard live else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

/// A key as it appears on the keyboard.
// KeyCap: Cookie's (CookieUI.swift), one look for keys in the app.
struct Sparkline: View {
    let values: [Double]
    var color: Color = Theme.brand
    @State private var drawn: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let path = Self.path(values, in: geometry.size)
            path.trim(from: 0, to: drawn)
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .onAppear { withAnimation(Theme.settle.speed(0.5)) { drawn = 1 } }
        .onChange(of: values) { _, _ in
            drawn = 0
            withAnimation(Theme.settle.speed(0.5)) { drawn = 1 }
        }
        .accessibilityHidden(true)
    }

    static func path(_ values: [Double], in size: CGSize) -> Path {
        Path { path in
            guard values.count > 1 else {
                path.move(to: CGPoint(x: 0, y: size.height - 1))
                path.addLine(to: CGPoint(x: size.width, y: size.height - 1))
                return
            }
            let top = max(values.max() ?? 1, 1)
            let step = size.width / CGFloat(values.count - 1)
            let points = values.enumerated().map { index, value in
                CGPoint(x: CGFloat(index) * step, y: size.height - 1 - CGFloat(value / top) * (size.height - 2))
            }
            path.move(to: points[0])
            for (previous, point) in zip(points, points.dropFirst()) {
                let middle = (previous.x + point.x) / 2
                path.addCurve(to: point, control1: CGPoint(x: middle, y: previous.y), control2: CGPoint(x: middle, y: point.y))
            }
        }
    }
}

/// The main action: Enkeon teal, white label.
struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// The dictation keys: Fn on Apple keyboards, ⌃⌘ on any keyboard.
struct DictationKeys: View {
    var body: some View {
        HStack(spacing: 5) {
            KeyCap(label: "fn")
            Text("or").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            KeyCap(label: "⌃")
            KeyCap(label: "⌘")
        }
    }
}
