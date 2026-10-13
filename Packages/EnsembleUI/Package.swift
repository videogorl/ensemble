// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "EnsembleUI",
    platforms: [
        .iOS(.v17),
        .macOS("15.0"),
        .watchOS(.v10)
    ],
    products: [
        .library(
            name: "EnsembleUI",
            targets: ["EnsembleUI"]
        ),
        .library(
            name: "EnsembleDesignTokens",
            targets: ["EnsembleDesignTokens"]
        ),
    ],
    dependencies: [
        .package(path: "../EnsembleSupport"),
        .package(path: "../EnsembleCore"),
        .package(path: "../EnsembleDomain"),
        .package(url: "https://github.com/kean/Nuke.git", from: "12.0.0"),
    ],
    targets: [
        .target(
            name: "EnsembleDesignTokens",
            dependencies: ["EnsembleDomain"],
            path: "DesignTokens"
        ),
        .target(
            name: "EnsembleUI",
            dependencies: [
                "EnsembleSupport",
                "EnsembleCore",
                "EnsembleDomain",
                "EnsembleDesignTokens",
                .product(name: "NukeUI", package: "Nuke"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "EnsembleUITests",
            dependencies: ["EnsembleUI", "EnsembleDesignTokens", "EnsembleDomain"],
            path: "Tests"
        ),
    ]
)
