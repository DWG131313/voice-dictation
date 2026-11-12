// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoiceDictation",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", exact: "1.1.1"),
    ],
    targets: [
        // Library target with all logic (testable)
        .target(
            name: "ObjCHelpers",
            path: "Sources/ObjCHelpers",
            publicHeadersPath: "include"
        ),
        .target(
            name: "VoiceDictationLib",
            dependencies: [
                "ObjCHelpers",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/VoiceDictationLib"
        ),
        // Thin executable — just the entry point
        .executableTarget(
            name: "VoiceDictation",
            dependencies: ["VoiceDictationLib"],
            path: "Sources/VoiceDictation"
        ),
        // Command-line engine comparison (`swift run vd-bench`)
        .executableTarget(
            name: "vd-bench",
            dependencies: ["VoiceDictationLib"],
            path: "Sources/VDBench"
        ),
        .testTarget(
            name: "VoiceDictationTests",
            dependencies: [
                "VoiceDictationLib",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Tests/VoiceDictationTests",
            resources: [.copy("Resources")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
