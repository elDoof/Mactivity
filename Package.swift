// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MactivityMonitor",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MactivityMonitor",
            path: "Sources")
    ]
)
