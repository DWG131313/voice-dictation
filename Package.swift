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
        .target(
            name: "VoiceDictationLib",
            dependencies: [
                "ObjCHelpers",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/VoiceDictationLib"
        ),
        // The SwiftUI side: the app model and the views (testable)
        .target(
            name: "VoiceDictationUI",
            dependencies: ["VoiceDictationLib"],
            path: "Sources/VoiceDictationUI"
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
        .testTarget(
            name: "VoiceDictationUITests",
            dependencies: ["VoiceDictationUI", "VoiceDictationLib"],
            path: "Tests/VoiceDictationUITests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
