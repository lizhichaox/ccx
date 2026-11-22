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
    ],
    targets: [
        .target(
            name: "CPXCapture",
            dependencies: [.product(name: "CPXCore", package: "CPXCore")]
        ),
        .testTarget(
            name: "CPXCaptureTests",
            dependencies: ["CPXCapture"]
        ),
    ]
)
