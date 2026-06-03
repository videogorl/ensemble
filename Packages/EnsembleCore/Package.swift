// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "EnsembleCore",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "EnsembleCore",
            targets: ["EnsembleCore"]
        ),
    ],
    dependencies: [
        .package(path: "../EnsembleSupport"),
        .package(path: "../EnsembleAPI"),
        .package(path: "../EnsemblePersistence"),
        .package(path: "../EnsembleSiriShared"),
        .package(url: "https://github.com/kean/Nuke.git", from: "12.0.0"),
    ],
    targets: [
        .target(
            name: "EnsembleCore",
            dependencies: [
                "EnsembleSupport",
                "EnsembleAPI",
                "EnsemblePersistence",
                "EnsembleSiriShared",
                "Nuke",
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "EnsembleCoreTests",
            dependencies: ["EnsembleCore", "EnsembleAPI"],
            path: "Tests"
        ),
    ]
)
