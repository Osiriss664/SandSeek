// swift-tools-version: 6.2
import PackageDescription

// The App/ folder (SwiftUI app, run controllers and their tests) is not part
// of this package yet: it still depends on TUFF app modules and is rebuilt in
// Abschnitt 3 of the plan. See App/README.md.
let package = Package(
    name: "SandSeek",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "SandSeekCore", targets: ["SandSeekCore"]),
        .executable(name: "sandseek", targets: ["sandseek"]),
    ],
    targets: [
        .target(
            name: "SandSeekCore",
            path: "Sources/SandSeekCore"
        ),
        .executableTarget(
            name: "sandseek",
            dependencies: ["SandSeekCore"],
            path: "Sources/sandseek"
        ),
        .testTarget(
            name: "SandSeekCoreTests",
            dependencies: ["SandSeekCore"],
            path: "Tests/SandSeekCoreTests"
        ),
    ]
)
