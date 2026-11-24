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
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Security"),
                .linkedFramework("Vision"),
            ]
        ),
        .testTarget(
            name: "CCXCoreTests",
            dependencies: ["CCXCore"]
        ),
    ]
)
