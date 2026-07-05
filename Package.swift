// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "claude-monitor",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "MonitorCore"),
        .executableTarget(name: "ClaudeMonitor", dependencies: ["MonitorCore"]),
        .testTarget(
            name: "MonitorCoreTests",
            dependencies: ["MonitorCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
