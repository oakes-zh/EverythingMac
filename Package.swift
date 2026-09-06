// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EverythingMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EverythingCore", targets: ["EverythingCore"]),
        .executable(name: "EverythingMac", targets: ["EverythingMac"])
    ],
    targets: [
        .target(name: "EverythingCore"),
        .executableTarget(name: "EverythingMac", dependencies: ["EverythingCore"]),
        .testTarget(name: "EverythingCoreTests", dependencies: ["EverythingCore"])
    ]
)
