// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Pane",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Pane",
            path: "Sources",
            resources: [
                .copy("pane-logo.png"),
                .copy("AppIcon.icns")
            ]
        )
    ]
)
