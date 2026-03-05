// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AgentsInBlack",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "aib-dev", targets: ["AIBCLI"]),
        .executable(name: "aib", targets: ["AIBCLI"]),
        .library(name: "AIBCore", targets: ["AIBCore"]),
        .library(name: "AIBRuntimeCore", targets: ["AIBRuntimeCore"]),
        .library(name: "AIBConfig", targets: ["AIBConfig"]),
        .library(name: "AIBGateway", targets: ["AIBGateway"]),
        .library(name: "AIBSupervisor", targets: ["AIBSupervisor"]),
        .library(name: "AIBWorkspace", targets: ["AIBWorkspace"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.74.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.25.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "6.2.0"),
        .package(url: "https://github.com/apple/containerization.git", from: "0.26.0"),
        .package(url: "https://github.com/apple/container.git", from: "0.10.0"),
    ],
    targets: [
        .target(
            name: "AIBCore",
            dependencies: [
                "AIBWorkspace",
                "AIBConfig",
                "AIBGateway",
                "AIBSupervisor",
                "AIBRuntimeCore",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .target(
            name: "AIBRuntimeCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "AIBConfig",
            dependencies: [
                "AIBRuntimeCore",
            ]
        ),
        .target(
            name: "AIBGateway",
            dependencies: [
                "AIBRuntimeCore",
                "AIBConfig",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "AIBSupervisor",
            dependencies: [
                "AIBRuntimeCore",
                "AIBConfig",
                "AIBGateway",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "SocketForwarder", package: "container"),
            ]
        ),
        .target(
            name: "AIBWorkspace",
            dependencies: [
                "AIBRuntimeCore",
                "AIBConfig",
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .executableTarget(
            name: "AIBCLI",
            dependencies: [
                "AIBCore",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "AIBConfigTests",
            dependencies: ["AIBConfig"]
        ),
        .testTarget(
            name: "AIBGatewayTests",
            dependencies: ["AIBGateway", "AIBTestSupport"]
        ),
        .testTarget(
            name: "AIBSupervisorTests",
            dependencies: ["AIBSupervisor", "AIBTestSupport"]
        ),
        .testTarget(
            name: "AIBWorkspaceTests",
            dependencies: ["AIBWorkspace"]
        ),
        .target(
            name: "AIBTestSupport",
            dependencies: ["AIBRuntimeCore", "AIBConfig"]
        ),
    ]
)
