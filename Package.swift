// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Ligma",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Ligma",
            path: "Sources",
            resources: [
                .copy("ligma-logo.png"),
                .copy("AppIcon.icns")
            ]
        )
    ]
)
