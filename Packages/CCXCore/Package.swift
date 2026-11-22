// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CCXCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CCXCore", targets: ["CCXCore"]),
    ],
    targets: [
        .target(
            name: "CCXCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
        .testTarget(
            name: "CCXCoreTests",
            dependencies: ["CCXCore"]
        ),
    ]
)
