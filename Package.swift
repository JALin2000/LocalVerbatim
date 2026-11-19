// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LocalVerbatim",
    platforms: [.macOS("15.0")],
    products: [.executable(name: "LocalVerbatim", targets: ["LocalVerbatim"])],
    targets: [.executableTarget(name: "LocalVerbatim", path: "Sources/LocalVerbatim")]
)
