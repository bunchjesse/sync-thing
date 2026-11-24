// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "SyncKit",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .library(name: "SyncKit", targets: ["SyncKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/bunchjesse/device-tunnel.git", .upToNextMinor(from: "0.1.0")),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.29.0", traits: []),
    ],
    targets: [
        .target(
            name: "SyncKit",
            dependencies: [
                .product(name: "DeviceTunnel", package: "device-tunnel"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
        .testTarget(
            name: "SyncKitTests",
            dependencies: ["SyncKit"]
        ),
    ]
)
