// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "EnsembleAPI",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .watchOS(.v8)
    ],
    products: [
        .library(
            name: "EnsembleAPI",
            targets: ["EnsembleAPI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.2.0"),
    ],
    targets: [
        .target(
            name: "EnsembleAPI",
            dependencies: ["KeychainAccess"],
            path: "Sources"
        ),
        .testTarget(
            name: "EnsembleAPITests",
            dependencies: ["EnsembleAPI"],
            path: "Tests"
        ),
    ]
)
