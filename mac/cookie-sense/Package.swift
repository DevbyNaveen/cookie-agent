// swift-tools-version:6.0
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
    targets: [
        .executableTarget(
            name: "cookie-sense",
            path: "Sources/cookie-sense",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist])]
        ),
    ],
    swiftLanguageModes: [.v5]
)
