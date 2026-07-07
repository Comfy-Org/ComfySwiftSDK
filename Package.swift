// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ComfySwiftSDK",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ComfySwiftSDK", targets: ["ComfySwiftSDK"]),
        // Batteries-included OAuth defaults (ASWebAuthenticationSession presenter +
        // Keychain token store). Kept in a SEPARATE product/target so it — and only
        // it — may import AuthenticationServices/Security without tripping the core
        // SDK's Foundation-only import boundary (ImportBoundaryTests scans
        // Sources/ComfySwiftSDK/ only). Apps that want full control depend on
        // ComfySwiftSDK alone and inject their own protocol conformances.
        .library(name: "ComfyAuthKit", targets: ["ComfyAuthKit"])
    ],
    targets: [
        .target(name: "ComfySwiftSDK"),
        .testTarget(name: "ComfySwiftSDKTests", dependencies: ["ComfySwiftSDK"]),
        .target(name: "ComfyAuthKit", dependencies: ["ComfySwiftSDK"]),
        .testTarget(name: "ComfyAuthKitTests", dependencies: ["ComfyAuthKit"])
    ]
)
