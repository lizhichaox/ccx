// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CCXRecord",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CCXRecord", targets: ["CCXRecord"]),
    ],
    dependencies: [
        .package(path: "../CCXCore"),
    ],
    targets: [
        .target(
            name: "CCXRecord",
            dependencies: [
                .product(name: "CCXCore", package: "CCXCore"),
            ]
        ),
        .testTarget(
            name: "CCXRecordTests",
            dependencies: ["CCXRecord"]
        ),
    ]
)
