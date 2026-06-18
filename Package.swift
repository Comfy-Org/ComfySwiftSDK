// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ComfySwiftSDK",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ComfySwiftSDK", targets: ["ComfySwiftSDK"])
    ],
    targets: [
        .target(name: "ComfySwiftSDK"),
        .testTarget(name: "ComfySwiftSDKTests", dependencies: ["ComfySwiftSDK"])
    ]
)
