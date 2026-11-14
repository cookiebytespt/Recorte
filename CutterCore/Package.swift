// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CutterCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CutterCore", targets: ["CutterCore"])
    ],
    targets: [
        .target(
            name: "CutterCore",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "CutterCoreTests",
            dependencies: ["CutterCore"]
        ),
    ]
)
