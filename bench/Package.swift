// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ASRBench",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
    ],
    targets: [
        .executableTarget(
            name: "ASRBench",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")]
        ),
    ]
)
