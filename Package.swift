// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "CodexNavigator", platforms: [.macOS(.v14)],
    products: [.executable(name: "CodexNavigator", targets: ["Navigator"])],
    targets: [.executableTarget(name: "Navigator", path: "Sources/Navigator", resources: [.copy("Resources/PurpleSurge")])])
