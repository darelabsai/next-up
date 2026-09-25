// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NextUp",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "NextUpCore", targets: ["NextUpCore"]),
        .executable(name: "NextUp", targets: ["NextUp"]),
    ],
    targets: [
        .target(name: "NextUpCore"),
        .executableTarget(name: "NextUp", dependencies: ["NextUpCore"]),
        .testTarget(
            name: "NextUpCoreTests",
            dependencies: ["NextUpCore"],
            resources: [.copy("Fixtures")]
        ),
        // Build the process fixture before tests, not inside a runner deadline.
        .executableTarget(name: "ProcessRunnerFixture", path: "Tests/ProcessRunnerFixture"),
        .testTarget(
            name: "NextUpTests",
            dependencies: ["NextUp", "NextUpCore", "ProcessRunnerFixture"]
        ),
    ]
)
