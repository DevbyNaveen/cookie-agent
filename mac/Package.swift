// swift-tools-version:5.9
// Builds Cookie with the Command Line Tools alone (no Xcode). `./build.sh` wraps it into Cookie.app.
import PackageDescription

let package = Package(
    name: "Cookie",
    platforms: [.macOS("14.2")],
    targets: [
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
