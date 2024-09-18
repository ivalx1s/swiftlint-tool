// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SwiftLintTool",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/realm/SwiftLint", from: "0.48.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.1.0")
    ],
    targets: [
        .executableTarget(
            name: "SwiftLintTool",
            dependencies: [
                .product(name: "SwiftLintFramework", package: "SwiftLint"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
    ]
)
