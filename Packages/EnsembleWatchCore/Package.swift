// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "EnsembleWatchCore",
    platforms: [
        .watchOS(.v10),
        .macOS("15.0")
    ],
    products: [
        .library(
            name: "EnsembleWatchCore",
            targets: ["EnsembleWatchCore"]
        ),
    ],
    dependencies: [
        .package(path: "../EnsembleAPI"),
        .package(path: "../EnsembleDomain"),
        .package(path: "../EnsemblePersistence"),
        .package(path: "../EnsemblePlex"),
    ],
    targets: [
        .target(
            name: "EnsembleWatchCore",
            dependencies: [
                "EnsembleAPI",
                "EnsembleDomain",
                "EnsemblePersistence",
                "EnsemblePlex",
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "EnsembleWatchCoreTests",
            dependencies: ["EnsembleWatchCore"],
            path: "Tests"
        ),
    ]
)
