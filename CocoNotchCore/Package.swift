// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CocoNotchCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "CocoNotchCore", targets: ["CocoNotchCore"])],
    targets: [
        .target(name: "CocoNotchCore"),
        .testTarget(name: "CocoNotchCoreTests", dependencies: ["CocoNotchCore"]),
    ]
)
