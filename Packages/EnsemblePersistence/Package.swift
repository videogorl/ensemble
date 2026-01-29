// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "EnsemblePersistence",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .watchOS(.v8)
    ],
    products: [
        .library(
            name: "EnsemblePersistence",
            targets: ["EnsemblePersistence"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "EnsemblePersistence",
            dependencies: [],
            path: "Sources",
            resources: [
                .process("CoreData/Ensemble.xcdatamodeld")
            ]
        ),
        .testTarget(
            name: "EnsemblePersistenceTests",
            dependencies: ["EnsemblePersistence"],
            path: "Tests"
        ),
    ]
)
