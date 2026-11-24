// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CCXAnnotate",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CCXAnnotate", targets: ["CCXAnnotate"]),
    ],
    dependencies: [
        .package(path: "../CCXCore"),
    ],
    targets: [
        .target(
            name: "CCXAnnotate",
            dependencies: [
                .product(name: "CCXCore", package: "CCXCore"),
            ]
        ),
        .testTarget(
            name: "CCXAnnotateTests",
            dependencies: [
                "CCXAnnotate",
                .product(name: "CCXCore", package: "CCXCore"),
            ]
        ),
    ]
)
