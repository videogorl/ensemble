// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "EnsemblePlex",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .watchOS(.v8)
    ],
    products: [
        .library(
            name: "EnsemblePlex",
            targets: ["EnsemblePlex"]
        ),
    ],
    dependencies: [
        .package(path: "../EnsembleAPI"),
        .package(path: "../EnsembleDomain"),
    ],
    targets: [
        .target(
            name: "EnsemblePlex",
            dependencies: [
                "EnsembleAPI",
                "EnsembleDomain",
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "EnsemblePlexTests",
            dependencies: ["EnsemblePlex"],
            path: "Tests"
        ),
    ]
)
