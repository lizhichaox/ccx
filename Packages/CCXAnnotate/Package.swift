// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CCXAnnotate",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CCXAnnotate", targets: ["CCXAnnotate"]),
    ],
    targets: [
        .target(
            name: "CCXAnnotate"
        ),
        .testTarget(
            name: "CCXAnnotateTests",
            dependencies: ["CCXAnnotate"]
        ),
    ]
)
