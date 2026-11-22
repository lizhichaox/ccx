// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CCXCapture",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CCXCapture", targets: ["CCXCapture"]),
    ],
    dependencies: [
        .package(path: "../CCXCore"),
        .package(path: "../CCXAnnotate"),
    ],
    targets: [
        .target(
            name: "CCXCapture",
            dependencies: [
                .product(name: "CCXCore", package: "CCXCore"),
                .product(name: "CCXAnnotate", package: "CCXAnnotate"),
            ]
        ),
        .testTarget(
            name: "CCXCaptureTests",
            dependencies: ["CCXCapture"]
        ),
    ]
)
