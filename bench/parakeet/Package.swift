// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PKBench",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", branch: "main"),
    ],
    targets: [
        .executableTarget(name: "PKBench", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
    ]
)
