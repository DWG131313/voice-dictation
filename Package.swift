// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoiceDictation",
    platforms: [.macOS(.v26)],
    products: [
        // The app target in project.yml links these two.
        .library(name: "VoiceDictationLib", targets: ["VoiceDictationLib"]),
        .library(name: "VoiceDictationUI", targets: ["VoiceDictationUI"]),
    ],
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
        // whisper.cpp v1.9.5 (commit d1be6fd), the version of the whisper-cli Danny
        // chose (D2), built by upstream from that commit as release b5454. Do not
        // bump it without recording Task 27's golden text again.
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
        ),
        .target(
            name: "VoiceDictationLib",
            dependencies: [
                "ObjCHelpers",
                "whisper",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/VoiceDictationLib"
        ),
        // The SwiftUI side: the app model and the views (testable)
        .target(
            name: "VoiceDictationUI",
            dependencies: ["VoiceDictationLib"],
            path: "Sources/VoiceDictationUI",
            resources: [.copy("Resources/Fonts")]
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
                // The tests read whisper.cpp's C types.
                "whisper",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Tests/VoiceDictationTests",
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "VoiceDictationUITests",
            dependencies: ["VoiceDictationUI", "VoiceDictationLib"],
            path: "Tests/VoiceDictationUITests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
