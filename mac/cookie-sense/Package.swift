// swift-tools-version:6.2
// cookie-sense: Cookie's eyes and ears in their own process. Builds with the Command Line Tools
// against the macOS 27 SDK (SpeechAnalyzer and the newest Vision need SDK 26+; this target uses
// no SwiftUI, so no macro plugin from Xcode is needed):
//   SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX27.sdk swift build -c release
import Foundation
import PackageDescription

// The Info.plist goes inside the executable (__TEXT,__info_plist): a helper without a bundle has
// no bundle identifier otherwise, and Vision's accurate text model has been seen to fail to load
// in exactly that kind of process (Apple forums 824639).
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Info.plist").path

let package = Package(
    name: "cookie-sense",
    platforms: [.macOS("15.0")],
    dependencies: [
        // Parakeet (on-device speech for meetings, and dictation when chosen), from Enkeon Voice.
        .package(url: "https://github.com/FluidInference/FluidAudio.git",
                 revision: "16d0a17471f3da6083b44aaea4c07d1989239140", traits: []),
    ],
    targets: [
        .executableTarget(
            name: "cookie-sense",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/cookie-sense",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist])]
        ),
    ],
    swiftLanguageModes: [.v5]
)
