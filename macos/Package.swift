// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeCockpit",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CockpitCore"),
        .executableTarget(name: "ClaudeCockpit", dependencies: ["CockpitCore"]),
        .testTarget(name: "CockpitCoreTests", dependencies: ["CockpitCore"]),
    ]
)
