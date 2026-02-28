// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "agent-swift-demo",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/1amageek/SwiftAgent.git", branch: "main"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "AgentSwift",
            dependencies: [
                .product(name: "SwiftAgent", package: "SwiftAgent"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "Sources"
        ),
    ]
)
