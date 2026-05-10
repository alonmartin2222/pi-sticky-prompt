// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PiStickyPrompt",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PiStickyPrompt",
            path: "Sources/PiStickyPrompt"
        )
    ]
)
