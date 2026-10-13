// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "EnsembleDomain",
    platforms: [
        .iOS(.v17),
        .macOS("15.0"),
        .watchOS(.v10)
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
