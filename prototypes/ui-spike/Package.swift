// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Soroband",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Soroband",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
