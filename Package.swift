// swift-tools-version: 6.0
// Developer convenience: `swift build` type-checks the whole app without Xcode.
// The shippable app bundle is produced by the XcodeGen project (project.yml).
import PackageDescription

let package = Package(
    name: "RecorteDev",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "CutterCore")
    ],
    targets: [
        .executableTarget(
            name: "Recorte",
            dependencies: [.product(name: "CutterCore", package: "CutterCore")],
            path: "App/Recorte",
            exclude: ["Info.plist", "Recorte.entitlements"],
            resources: [.process("Localizable.xcstrings")]
        )
    ]
)
