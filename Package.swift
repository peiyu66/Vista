// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "VistaCore", platforms: [.macOS(.v14), .visionOS(.v2)],
    products: [.library(name: "VistaCore", targets: ["VistaCore"]), .library(name: "VistaSMB", targets: ["VistaSMB"])],
    dependencies: [.package(path: "Dependencies/AMSMB2")],
    targets: [.target(name: "VistaCore", resources: [.copy("Resources/Synthetic.mp4"), .copy("Resources/SyntheticVR.mp4")]), .target(name: "VistaMedia", dependencies: ["VistaCore"]), .target(name: "VistaSMB", dependencies: ["VistaCore", .product(name: "AMSMB2", package: "AMSMB2")]), .testTarget(name: "VistaCoreTests", dependencies: ["VistaCore", "VistaSMB", "VistaMedia"], resources: [.copy("Resources/OpenGOPHEVC.mp4"),.copy("Resources/CalibrationSBS180.mp4"),.copy("Resources/CalibrationOU180.mp4"),.copy("Resources/CalibrationSBS360.mp4"),.copy("Resources/CalibrationOU360.mp4"),.copy("Resources/SyntheticAV.mp4"), .copy("Resources/SyntheticSeek.mp4"), .copy("Resources/SyntheticHEVC.mp4"), .copy("Resources/Synthetic4KHEVC.mp4"), .copy("Resources/Synthetic4KH264.mp4"), .copy("Resources/SyntheticVP9.mp4"), .copy("Resources/SyntheticVP9.mkv")])])
