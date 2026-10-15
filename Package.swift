// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Hush",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Hush", targets: ["HushApp"]),
        .library(name: "HushKit", targets: ["HushKit"]),
    ],
    targets: [
        .target(name: "MuesliCore", path: "Vendor/Muesli/MuesliCore"),
        .target(name: "MuesliAudio", dependencies: ["MuesliCore"], path: "Vendor/Muesli/MuesliAudio"),
        .target(name: "MuesliTranscribe", dependencies: ["MuesliCore", "MuesliAudio"], path: "Vendor/Muesli/MuesliTranscribe"),
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "HushKit", dependencies: ["MuesliCore", "MuesliAudio", "MuesliTranscribe", "CSQLite"]),
        .executableTarget(name: "HushApp", dependencies: ["HushKit", "MuesliCore", "MuesliAudio", "MuesliTranscribe"]),
        .testTarget(name: "HushKitTests", dependencies: ["HushKit", "MuesliCore", "MuesliAudio", "MuesliTranscribe"]),
        .testTarget(name: "HushAppTests", dependencies: ["HushApp", "HushKit"]),
        .testTarget(name: "MuesliCoreTests", dependencies: ["MuesliCore"]),
        .testTarget(name: "MuesliAudioTests", dependencies: ["MuesliAudio"]),
    ],
    swiftLanguageModes: [.v6]
)
