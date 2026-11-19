// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "EnsembleCore",
    platforms: [
        .iOS(.v17),
        .macOS("15.0")
    ],
    products: [
        .library(
            name: "EnsembleCore",
            targets: ["EnsembleCore"]
        ),
    ],
    dependencies: [
        .package(path: "../EnsembleSupport"),
        .package(path: "../EnsembleDomain"),
        .package(path: "../EnsembleAPI"),
        .package(path: "../EnsemblePersistence"),
        .package(path: "../EnsembleSiriShared"),
        .package(url: "https://github.com/kean/Nuke.git", from: "12.0.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms.git", from: "1.1.7"),
    ],
    targets: [
        .target(
            name: "EnsembleCore",
            dependencies: [
                "EnsembleSupport",
                "EnsembleDomain",
                "EnsembleAPI",
                "EnsemblePersistence",
                "EnsembleSiriShared",
                "Nuke",
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "EnsembleCoreTests",
            dependencies: ["EnsembleCore", "EnsembleAPI", "EnsembleDomain"],
            path: "Tests"
        ),
    ]
)
