// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Recents",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Recents",
            path: "Sources/Recents",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RecentsTests",
            dependencies: ["Recents"],
            path: "Tests/RecentsTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
