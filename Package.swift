// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "VistaCore", platforms: [.macOS(.v14), .visionOS(.v2)],
    products: [.library(name: "VistaCore", targets: ["VistaCore"]), .library(name: "VistaSMB", targets: ["VistaSMB"])],
    dependencies: [.package(url: "https://github.com/amosavian/AMSMB2.git", exact: "4.0.3")],
    targets: [.target(name: "VistaCore", resources: [.copy("Resources/Synthetic.mp4"), .copy("Resources/SyntheticVR.mp4")]), .target(name: "VistaMedia", dependencies: ["VistaCore"]), .target(name: "VistaSMB", dependencies: ["VistaCore", .product(name: "AMSMB2", package: "AMSMB2")]), .testTarget(name: "VistaCoreTests", dependencies: ["VistaCore", "VistaSMB", "VistaMedia"], resources: [.copy("Resources/SyntheticAV.mp4"), .copy("Resources/SyntheticSeek.mp4"), .copy("Resources/SyntheticHEVC.mp4")])])
