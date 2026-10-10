// swift-tools-version: 6.2
import PackageDescription

// SandSeekCore is the research loop, and `sandseek` is the command that runs
// it. SandSeekAppLogic holds what the app does apart from drawing (runs,
// sandbox, reports, server connection, presets), so it can be tested without
// a window; SandSeekApp is the SwiftUI window. The app targets need macOS
// (SwiftUI, AppKit, CryptoKit), so they are added on macOS only and the core
// and the command still build and test elsewhere.
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

#if os(macOS)
package.products += [
    .library(name: "SandSeekAppLogic", targets: ["SandSeekAppLogic"]),
    .executable(name: "SandSeekApp", targets: ["SandSeekApp"]),
]
package.targets += [
    .target(
        name: "SandSeekAppLogic",
        dependencies: ["SandSeekCore"],
        path: "Sources/SandSeekAppLogic"
    ),
    // The window. The `@main` struct is in SandSeekApplication.swift, not in a
    // main.swift. `Scripts/package_app.sh` builds this into SandSeek.app.
    .executableTarget(
        name: "SandSeekApp",
        dependencies: ["SandSeekAppLogic", "SandSeekCore"],
        path: "Sources/SandSeekApp"
    ),
    .testTarget(
        name: "SandSeekAppLogicTests",
        dependencies: ["SandSeekAppLogic", "SandSeekCore"],
        path: "Tests/SandSeekAppLogicTests"
    ),
]
#endif
