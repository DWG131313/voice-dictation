// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceDictation",
    platforms: [.macOS(.v13)],
    targets: [
        // Library target with all logic (testable)
        .target(
            name: "ObjCHelpers",
            path: "Sources/ObjCHelpers",
            publicHeadersPath: "include"
        ),
        .target(
            name: "VoiceDictationLib",
            dependencies: ["ObjCHelpers"],
            path: "Sources/VoiceDictationLib"
        ),
        // Thin executable — just the entry point
        .executableTarget(
            name: "VoiceDictation",
            dependencies: ["VoiceDictationLib"],
            path: "Sources/VoiceDictation"
        ),
        .testTarget(
            name: "VoiceDictationTests",
            dependencies: ["VoiceDictationLib"],
            path: "Tests/VoiceDictationTests"
        ),
    ]
)
