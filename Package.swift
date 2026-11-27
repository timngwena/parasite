// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Parasite",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Parasite",
            path: "Sources/Parasite",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
