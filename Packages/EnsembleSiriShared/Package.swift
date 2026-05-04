// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "EnsembleSiriShared",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .watchOS(.v8)
    ],
    products: [
        .library(
            name: "EnsembleSiriShared",
            targets: ["EnsembleSiriShared"]
        ),
    ],
    targets: [
        .target(
            name: "EnsembleSiriShared",
            path: "Sources"
        ),
        .testTarget(
            name: "EnsembleSiriSharedTests",
            dependencies: ["EnsembleSiriShared"],
            path: "Tests"
        ),
    ]
)
