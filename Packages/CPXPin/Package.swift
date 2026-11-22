// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CPXPin",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CPXPin", targets: ["CPXPin"]),
    ],
    dependencies: [
        .package(path: "../CPXCore"),
    ],
    targets: [
        .target(
            name: "CPXPin",
            dependencies: [
                .product(name: "CPXCore", package: "CPXCore"),
            ]
        ),
        .testTarget(
            name: "CPXPinTests",
            dependencies: ["CPXPin"]
        ),
    ]
)
