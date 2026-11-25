// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LightboxCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LightboxCore", targets: ["LightboxCore"])
    ],
    targets: [
        .target(name: "LightboxCore"),
        .testTarget(
            name: "LightboxCoreTests", dependencies: ["LightboxCore"], resources: [.copy("Fixtures")]),
    ]
)
