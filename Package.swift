// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UsageBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "UsageBar", targets: ["UsageBar"])],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(name: "UsageBar", dependencies: ["UsageCore"], resources: [.process("Resources")]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
    ]
)
