// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "EnsemblePlex",
    platforms: [
        .iOS(.v17),
        .macOS("15.0"),
        .watchOS(.v10)
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
            dependencies: ["EnsembleAPI", "EnsemblePlex"],
            path: "Tests"
        ),
    ]
)
