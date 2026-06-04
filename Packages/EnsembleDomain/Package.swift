// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "EnsembleDomain",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .watchOS(.v8)
    ],
    products: [
        .library(
            name: "EnsembleDomain",
            targets: ["EnsembleDomain"]
        ),
    ],
    targets: [
        .target(
            name: "EnsembleDomain",
            path: "Sources"
        ),
        .testTarget(
            name: "EnsembleDomainTests",
            dependencies: ["EnsembleDomain"],
            path: "Tests"
        ),
    ]
)
