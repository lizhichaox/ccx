// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CPXAnnotate",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CPXAnnotate", targets: ["CPXAnnotate"]),
    ],
    targets: [
        .target(
            name: "CPXAnnotate"
        ),
        .testTarget(
            name: "CPXAnnotateTests",
            dependencies: ["CPXAnnotate"]
        ),
    ]
)
