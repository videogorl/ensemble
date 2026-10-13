// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "EnsembleSupport",
    platforms: [
        .iOS(.v17),
        .macOS("15.0"),
        .watchOS(.v10)
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
