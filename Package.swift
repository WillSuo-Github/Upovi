// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Upovi",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Upovi", targets: ["Upovi"]),
        .executable(name: "UpoviPeer", targets: ["UpoviPeer"]),
        .library(name: "UpoviCore", targets: ["UpoviCore"])
    ],
    targets: [
        .target(name: "ArchiveSupport", cSettings: [.headerSearchPath("vendor")], linkerSettings: [.linkedLibrary("archive")]),
        .target(name: "UpoviCore", dependencies: ["ArchiveSupport"]),
        .executableTarget(name: "Upovi", dependencies: ["UpoviCore"]),
        .executableTarget(name: "UpoviPeer", dependencies: ["UpoviCore"]),
        .testTarget(name: "UpoviCoreTests", dependencies: ["UpoviCore"])
    ]
)
