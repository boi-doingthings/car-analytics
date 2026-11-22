// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "I20Core",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "I20Core", targets: ["I20Core"])],
    targets: [
        .target(name: "I20Core"),
        .testTarget(
            name: "I20CoreTests",
            dependencies: ["I20Core"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
