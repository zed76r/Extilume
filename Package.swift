// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Extilume",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "extilume-probe", targets: ["ExtilumeProbe"]),
        .executable(name: "Extilume", targets: ["ExtilumeApp"])
    ],
    targets: [
        .target(name: "ExtilumeCore"),
        .target(name: "ExtilumeNative", dependencies: ["ExtilumeCore"]),
        .executableTarget(name: "ExtilumeProbe", dependencies: ["ExtilumeNative"], path: "Sources/extilume-probe"),
        .executableTarget(name: "ExtilumeApp", dependencies: ["ExtilumeNative"]),
        .testTarget(name: "ExtilumeCoreTests", dependencies: ["ExtilumeCore"]),
        .testTarget(name: "ExtilumeNativeTests", dependencies: ["ExtilumeNative", "ExtilumeCore"])
    ]
)
