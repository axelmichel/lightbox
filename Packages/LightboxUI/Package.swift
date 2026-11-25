// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LightboxUI",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LightboxUI", targets: ["LightboxUI"])
    ],
    dependencies: [
        .package(path: "../ComfyKit"),
        .package(path: "../LightboxCore"),
    ],
    targets: [
        .target(name: "LightboxUI", dependencies: ["ComfyKit", "LightboxCore"]),
        .testTarget(name: "LightboxUITests", dependencies: ["LightboxUI", "ComfyKit", "LightboxCore"]),
    ]
)
