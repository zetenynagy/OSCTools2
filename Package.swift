// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "OSCTools2",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "OSCTools2", targets: ["OSCTools2"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orchetect/OSCKit", from: "1.2.1"),
        // OSCKit's existing socket dependency, used to constrain UDP routing.
        .package(url: "https://github.com/robbiehanson/CocoaAsyncSocket", from: "7.6.5"),
        .package(url: "https://github.com/heestand-xyz/Logger", from: "0.3.0"),
        .package(url: "https://github.com/rwbutler/connectivity", from: "6.1.1"),
    ],
    targets: [
        .target(
            name: "OSCTools2",
            dependencies: [
                "OSCKit",
                "CocoaAsyncSocket",
                .product(name: "Connectivity", package: "connectivity"),
                "Logger"
            ]
        ),
        .testTarget(
            name: "OSCTools2Tests",
            dependencies: ["OSCTools2"]
        ),
    ]
)
