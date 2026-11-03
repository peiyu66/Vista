// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "VistaCore", platforms: [.macOS(.v14), .visionOS(.v2)],
    products: [.library(name: "VistaCore", targets: ["VistaCore"]), .library(name: "VistaSMB", targets: ["VistaSMB"])],
    dependencies: [.package(url: "https://github.com/amosavian/AMSMB2.git", exact: "4.0.3")],
    targets: [.target(name: "VistaCore"), .target(name: "VistaSMB", dependencies: ["VistaCore", .product(name: "AMSMB2", package: "AMSMB2")]), .testTarget(name: "VistaCoreTests", dependencies: ["VistaCore", "VistaSMB"])])
