// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Extilume",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "extilume-probe", targets: ["ExtilumeProbe"])
    ],
    targets: [
        .target(name: "ExtilumeCore"),
        .executableTarget(name: "ExtilumeProbe", dependencies: ["ExtilumeCore"], path: "Sources/extilume-probe"),
        .testTarget(name: "ExtilumeCoreTests", dependencies: ["ExtilumeCore"])
    ]
)
