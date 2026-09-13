// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "AgentLease",
    platforms: [
        .macOS(.v27),
    ],
    products: [
        .library(name: "AgentLeaseCore", targets: ["AgentLeaseCore"]),
        .executable(name: "agentlease", targets: ["agentlease"]),
        .executable(name: "agentlease-spike-helper", targets: ["AgentLeaseSpikeHelper"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            .upToNextMinor(from: "1.8.2")
        ),
        .package(
            url: "https://github.com/swiftlang/swift-subprocess.git",
            .upToNextMinor(from: "1.0.0")
        ),
    ],
    targets: [
        .target(
            name: "AgentLeaseCore",
            dependencies: [
                .product(name: "Subprocess", package: "swift-subprocess"),
            ]
        ),
        .executableTarget(
            name: "agentlease",
            dependencies: [
                "AgentLeaseCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "AgentLeaseSpikeHelper",
            dependencies: ["AgentLeaseCore"]
        ),
        .testTarget(
            name: "AgentLeaseCoreTests",
            dependencies: ["AgentLeaseCore"]
        ),
        .testTarget(
            name: "AgentLeaseCLITests",
            dependencies: ["AgentLeaseCore"]
        ),
    ]
)
