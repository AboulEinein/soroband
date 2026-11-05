// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IslandSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "IslandSpike", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
