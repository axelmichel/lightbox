// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ComfyKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ComfyKit", targets: ["ComfyKit"])
    ],
    targets: [
        .target(name: "ComfyKit"),
        .testTarget(
            name: "ComfyKitTests",
            dependencies: ["ComfyKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
