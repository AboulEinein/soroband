// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PopoverSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PopoverSpike", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
