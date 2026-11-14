// swift-tools-version:5.9
// Builds Enkeon with the Command Line Tools alone (no Xcode), as Cookie does:
//   SDKROOT="$(scripts/sdk.sh app)" swift build --build-system native
//   SDKROOT="$(scripts/sdk.sh app)" swift run --build-system native EnkeonVoiceKitChecks
// The speech helper is its own package: Helpers/enkeon-sense (SDK 26+), checked by scripts/check-sense.py.
// EnkeonVoiceKit is the dictation core; Cookie (cookie-harness) imports it too.
import PackageDescription

let package = Package(
    name: "Enkeon",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "EnkeonVoiceKit", targets: ["EnkeonVoiceKit"]),
    ],
    targets: [
        .target(name: "EnkeonVoiceKit"),
        // The standalone Enkeon app lives on at git tag enkeon-voice-app-v0; its views are in Cookie now.
        // No XCTest with the Command Line Tools alone: checks are preconditions, as in Cookie.
        .executableTarget(name: "EnkeonVoiceKitChecks", dependencies: ["EnkeonVoiceKit"]),
    ]
)
