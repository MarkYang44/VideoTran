// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VideoTran",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "VideoTran", targets: ["VideoTran"])],
    targets: [
        .target(name: "SubtitleCore"),
        .executableTarget(name: "VideoTran", dependencies: ["SubtitleCore"]),
        .executableTarget(name: "SubtitleCoreTests", dependencies: ["SubtitleCore"], path: "Tests/SubtitleCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
