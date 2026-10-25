// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Upovi",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Upovi", targets: ["Upovi"]),
        .executable(name: "UpoviPeer", targets: ["UpoviPeer"]),
        .executable(name: "UpoviInstaller", targets: ["UpoviInstaller"]),
        .library(name: "UpoviCore", targets: ["UpoviCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "ArchiveSupport", cSettings: [.headerSearchPath("vendor")], linkerSettings: [.linkedLibrary("archive")]),
        .target(name: "UpoviCore", dependencies: ["ArchiveSupport"]),
        .executableTarget(name: "Upovi", dependencies: ["UpoviCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "UpoviPeer", dependencies: ["UpoviCore"]),
        .executableTarget(name: "UpoviInstaller", dependencies: ["UpoviCore"]),
        .testTarget(name: "UpoviCoreTests", dependencies: ["UpoviCore"])
    ]
)
