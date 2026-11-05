// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "sbtfix",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SonyProtocol"),
        .executableTarget(name: "sbtfix", dependencies: ["SonyProtocol"]),
        .testTarget(name: "SonyProtocolTests", dependencies: ["SonyProtocol"]),
        .testTarget(name: "sbtfixTests", dependencies: ["sbtfix"]),
    ]
)
