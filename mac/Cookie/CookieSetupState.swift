import Combine
import Foundation

enum CookieSetupStep: Int, CaseIterable, Identifiable {
    case welcome, voice, screen, shortcuts, ready
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .welcome: return "Welcome"
        case .voice: return "Voice"
        case .screen: return "Screen"
        case .shortcuts: return "Shortcuts"
        case .ready: return "Ready"
        }
    }
}

@MainActor
final class CookieSetupProgress: ObservableObject {
    @Published private(set) var step: CookieSetupStep
    private let defaults: UserDefaults
    private let persistsProgress: Bool
    static let stepKey = "cookie.setup.step"
    static let completedKey = "hasCompletedOnboarding"

    init(defaults: UserDefaults = .standard, replay: Bool = false) {
        self.defaults = defaults
        persistsProgress = !replay
        step = replay ? .welcome : CookieSetupStep(rawValue: defaults.integer(forKey: Self.stepKey)) ?? .welcome
    }

    func advance() { move(to: CookieSetupStep(rawValue: step.rawValue + 1) ?? .ready) }
    func back() { move(to: CookieSetupStep(rawValue: step.rawValue - 1) ?? .welcome) }
    private func move(to destination: CookieSetupStep) {
        step = destination
        if persistsProgress { defaults.set(step.rawValue, forKey: Self.stepKey) }
    }

    func complete() {
        guard step == .ready else { return }
        defaults.set(true, forKey: Self.completedKey)
        defaults.removeObject(forKey: Self.stepKey)
    }
}
