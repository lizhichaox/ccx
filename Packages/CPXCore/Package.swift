// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CPXCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CPXCore", targets: ["CPXCore"]),
    ],
    targets: [
        .target(
            name: "CPXCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
        .testTarget(
            name: "CPXCoreTests",
            dependencies: ["CPXCore"]
        ),
    ]
)
