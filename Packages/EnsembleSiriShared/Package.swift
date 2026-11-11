// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "EnsembleSiriShared",
    platforms: [
        .iOS(.v17),
        .macOS("15.0"),
        .watchOS(.v10)
    ],
    products: [
        .library(
            name: "EnsembleSiriShared",
            targets: ["EnsembleSiriShared"]
        ),
    ],
    dependencies: [
        .package(path: "../EnsembleSupport"),
        .package(path: "../EnsembleDomain"),
    ],
    targets: [
        .target(
            name: "EnsembleSiriShared",
            dependencies: ["EnsembleSupport", "EnsembleDomain"],
            path: "Sources"
        ),
        .testTarget(
            name: "EnsembleSiriSharedTests",
            dependencies: ["EnsembleSiriShared", "EnsembleDomain"],
            path: "Tests"
        ),
    ]
)
