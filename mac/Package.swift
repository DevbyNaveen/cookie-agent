// swift-tools-version:5.9
// Builds Cookie with the Command Line Tools alone (no Xcode). `./build.sh` wraps it into Cookie.app.
import PackageDescription

let package = Package(
    name: "Cookie",
    platforms: [.macOS("15.0")],
    targets: [
        // Enkeon dictation, shared with the parked standalone app under voice/ (git tag enkeon-voice-app-v0).
        .target(name: "EnkeonVoiceKit", path: "voice/Sources/EnkeonVoiceKit"),
        .executableTarget(
            name: "Cookie",
            path: "Cookie",
            exclude: [
                "Info.plist", "Cookie.entitlements", "Assets.xcassets",
                "AppIcon.icns", "AppIcon-1024.png",
            ]
        ),
    ]
)
