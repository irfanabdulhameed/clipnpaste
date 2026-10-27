// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Clipnpaste",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "ClipnpasteCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Clipnpaste",
            dependencies: ["ClipnpasteCore"]
        ),
        .testTarget(
            name: "ClipnpasteCoreTests",
            dependencies: ["ClipnpasteCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
