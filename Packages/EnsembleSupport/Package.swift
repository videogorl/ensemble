// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "EnsembleSupport",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .watchOS(.v8)
    ],
    products: [
        .library(
            name: "EnsembleSupport",
            targets: ["EnsembleSupport"]
        ),
    ],
    targets: [
        .target(
            name: "EnsembleSupport",
            path: "Sources"
        ),
        .testTarget(
            name: "EnsembleSupportTests",
            dependencies: ["EnsembleSupport"],
            path: "Tests"
        ),
    ]
)
