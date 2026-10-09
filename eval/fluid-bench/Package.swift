// swift-tools-version: 6.0
// Runs MyType's current engine (FluidAudio 0.13.6, Qwen3-ASR 0.6B CoreML int8) over the same inputs as asr-bench.
import PackageDescription

let package = Package(
    name: "fluid-bench",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.13.6"),
    ],
    targets: [
        .executableTarget(
            name: "fluid-bench",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
