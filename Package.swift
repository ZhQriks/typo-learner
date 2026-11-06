// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TypoLearner",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "TypoCore"),
        .executableTarget(name: "TypoLearner", dependencies: ["TypoCore"]),
        .testTarget(name: "TypoCoreTests", dependencies: ["TypoCore"]),
    ],
    swiftLanguageModes: [.v5]
)
