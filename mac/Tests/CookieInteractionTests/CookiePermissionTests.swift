import Foundation

/// The screen-recording permission prompt: macOS shows its own prompt once,
/// after that the only way in is System Settings.
@MainActor
enum CookiePermissionTests {
    static func run() {
        testFirstPermissionRequestUsesSystemPromptOnly()
        testRepeatedPermissionRequestOpensSystemSettings()
        testKnownGrantedScreenRecordingPermissionSkipsTheGate()
        print("3 permission checks passed.")
    }

    private static func testFirstPermissionRequestUsesSystemPromptOnly() {
        precondition(WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false, hasAttemptedSystemPrompt: false) == .systemPrompt)
    }

    private static func testRepeatedPermissionRequestOpensSystemSettings() {
        precondition(WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false, hasAttemptedSystemPrompt: true) == .systemSettings)
    }

    private static func testKnownGrantedScreenRecordingPermissionSkipsTheGate() {
        precondition(WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false, hasPreviouslyConfirmedScreenRecordingPermission: true))
    }
}
