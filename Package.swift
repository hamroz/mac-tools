// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacTools",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MacToolsCore", targets: ["MacToolsCore"]),
        .executable(name: "MacTools", targets: ["MacTools"])
    ],
    targets: [
        .target(name: "MacToolsCore"),
        .executableTarget(
            name: "MacTools",
            dependencies: ["MacToolsCore"]
        ),
        .testTarget(
            name: "MacToolsCoreTests",
            dependencies: ["MacToolsCore"]
        ),
        .testTarget(
            name: "MacToolsAppTests",
            dependencies: ["MacTools", "MacToolsCore"]
        )
    ]
)
