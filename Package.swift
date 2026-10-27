// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "T3Notch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "T3Notch",
            path: "Sources/T3Notch",
            linkerSettings: [.linkedLibrary("sqlite3")] // EditStats: live +/- from T3's local store
        ),
        .testTarget(
            name: "T3NotchTests",
            dependencies: ["T3Notch"],
            path: "Tests/T3NotchTests"
        ),
    ]
)
