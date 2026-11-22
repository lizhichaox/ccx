// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CPXCapture",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CPXCapture", targets: ["CPXCapture"]),
    ],
    dependencies: [
        .package(path: "../CPXCore"),
        .package(path: "../CPXAnnotate"),
    ],
    targets: [
        .target(
            name: "CPXCapture",
            dependencies: [
                .product(name: "CPXCore", package: "CPXCore"),
                .product(name: "CPXAnnotate", package: "CPXAnnotate"),
            ]
        ),
        .testTarget(
            name: "CPXCaptureTests",
            dependencies: ["CPXCapture"]
        ),
    ]
)
