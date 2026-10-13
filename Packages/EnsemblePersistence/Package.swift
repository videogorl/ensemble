// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "EnsemblePersistence",
    platforms: [
        .iOS(.v17),
        .macOS("15.0"),
        .watchOS(.v10)
    ],
    products: [
        .library(
            name: "EnsemblePersistence",
            targets: ["EnsemblePersistence"]
        ),
    ],
    dependencies: [
        .package(path: "../EnsembleSupport"),
    ],
    targets: [
        .target(
            name: "EnsemblePersistence",
            dependencies: ["EnsembleSupport"],
            path: "Sources",
            resources: [
                .process("CoreData/Ensemble.xcdatamodeld"),
                .copy("CoreData/Compiled/SwiftPMEnsemble.momd")
            ]
        ),
        .testTarget(
            name: "EnsemblePersistenceTests",
            dependencies: ["EnsemblePersistence"],
            path: "Tests"
        ),
    ]
)
