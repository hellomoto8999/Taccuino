// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Taccuino",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Taccuino",
            path: "Sources/Taccuino",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
