// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CCXPin",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CCXPin", targets: ["CCXPin"]),
    ],
    dependencies: [
        .package(path: "../CCXCore"),
        .package(path: "../CCXAnnotate"),
    ],
    targets: [
        .target(
            name: "CCXPin",
            dependencies: [
                .product(name: "CCXCore", package: "CCXCore"),
                .product(name: "CCXAnnotate", package: "CCXAnnotate"),
            ]
        ),
        .testTarget(
            name: "CCXPinTests",
            dependencies: ["CCXPin"]
        ),
    ]
)
