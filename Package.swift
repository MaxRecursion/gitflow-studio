// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitFlowStudio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GitCore", targets: ["GitCore"]),
        .executable(name: "GitFlowStudio", targets: ["GitFlowStudio"]),
        .executable(name: "GitBenchmarks", targets: ["GitBenchmarks"])
    ],
    targets: [
        .target(name: "GitCore"),
        .executableTarget(name: "GitFlowStudio", dependencies: ["GitCore"]),
        .executableTarget(name: "GitBenchmarks", dependencies: ["GitCore"]),
        .testTarget(name: "GitCoreTests", dependencies: ["GitCore"])
    ]
)
