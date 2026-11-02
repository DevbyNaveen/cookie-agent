// swift-tools-version:6.2
// enkeon-sense: Enkeon's speech recognition in its own process. Builds with the Command Line Tools
// against a macOS 26+ SDK (SpeechAnalyzer needs SDK 26; no SwiftUI, so no Xcode macro plugin):
//   SDKROOT="$(../../scripts/sdk.sh sense)" swift build -c release
import Foundation
import PackageDescription

// The Info.plist goes inside the executable (__TEXT,__info_plist): a helper without a bundle has
// no bundle identifier or speech usage string otherwise.
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Info.plist").path

let package = Package(
    name: "enkeon-sense",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git",
                 revision: "16d0a17471f3da6083b44aaea4c07d1989239140", traits: []),
    ],
    targets: [
        .executableTarget(
            name: "enkeon-sense",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/enkeon-sense",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist])]
        ),
    ],
    swiftLanguageModes: [.v5]
)
