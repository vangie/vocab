// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Vocab",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Vocab", targets: ["Vocab"]),
        .executable(name: "vocab-smoke", targets: ["vocab-smoke"]),
    ],
    targets: [
        .target(name: "CMultitouch"),
        .target(
            name: "VocabCore",
            dependencies: ["CMultitouch"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "Vocab", dependencies: ["VocabCore"]),
        .executableTarget(name: "vocab-smoke", dependencies: ["VocabCore"]),
        .testTarget(name: "VocabCoreTests", dependencies: ["VocabCore", "CMultitouch"]),
    ],
    swiftLanguageModes: [.v5]
)
