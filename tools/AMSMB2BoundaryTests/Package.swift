// swift-tools-version: 6.0
import PackageDescription

// Isolated, network-free harness. Symlinks reference the candidate's actual
// Swift and C sources; the upstream dependency test suite is not included.
let package = Package(
    name: "Build64DependencyValidation",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "libsmb2", path: "SMB2C",
            exclude: ["lib/CMakeLists.txt", "lib/libsmb2.syms", "lib/Makefile.am",
                      "lib/Makefile.AMIGA", "lib/Makefile.AMIGA_AROS", "lib/Makefile.AMIGA_OS3",
                      "lib/Makefile.PS3_PPU", "lib/ps2"],
            sources: ["lib"], publicHeadersPath: "include",
            cSettings: [.headerSearchPath("include"), .headerSearchPath("include/apple"),
                        .headerSearchPath("include/smb2"), .headerSearchPath("lib"),
                        .define("_U_", to: "__attribute__((unused))"), .define("HAVE_CONFIG_H", to: "1")]
        ),
        .target(name: "AMSMB2", dependencies: ["libsmb2"], path: "AMSMB2Swift",
                swiftSettings: [.enableUpcomingFeature("ExistentialAny")]),
        .testTarget(name: "BoundaryTests", dependencies: ["AMSMB2"], path: "Tests")
    ]
)
