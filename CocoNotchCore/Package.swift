// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CocoNotchCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CocoNotchCore", targets: ["CocoNotchCore"])],
    targets: [
        .target(name: "CocoNotchCore", swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(name: "CocoNotchCoreTests", dependencies: ["CocoNotchCore"]),
    ]
)
