// swift-tools-version:6.0
import PackageDescription

// Pip's platform-free core: cue language, procedure runtime, policy, memory, prompts and API
// clients. No UIKit or ARKit, so it builds and tests on macOS and is shared with PipEval.
let package = Package(
    name: "PipCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PipCore", targets: ["PipCore"]),
        .executable(name: "pipeval", targets: ["pipeval"]),
    ],
    targets: [
        .target(name: "PipCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "pipeval", dependencies: ["PipCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "PipCoreTests", dependencies: ["PipCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
