// swift-tools-version: 6.0
// Runs Qwen3-ASR (soniqo/speech-swift) over MyType's saved recordings for the eval (docs/design-otto-context.md).
import PackageDescription

let package = Package(
    name: "asr-bench",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/soniqo/speech-swift.git", exact: "0.0.28"),
    ],
    targets: [
        .executableTarget(
            name: "asr-bench",
            dependencies: [
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
