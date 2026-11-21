import CoreGraphics
import Foundation
import ImageIO
import XCTest

/// The app icon (Danny's design, 2026-11-20): `scripts/make-icon.swift` draws
/// a sharp waveform in the spectrum on a black rounded square, in the
/// colours of DESIGN.md's tokens. These tests run the script itself on a
/// DESIGN.md of their own, into a temporary folder, and check the icon set
/// the app is built with.
final class AppIconTests: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // VoiceDictationUITests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // the package
    private static let iconSet = repo.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")

    /// Colours far from the real tokens, so a pixel shows which token drew it.
    private static let tokens = [
        "bg": "#202830",
        "spectrum-1": "#FF0000", "spectrum-2": "#FFFF00", "spectrum-3": "#00FF00",
        "spectrum-4": "#00FFFF", "spectrum-5": "#FF00FF", "spectrum-6": "#0000FF",
    ]

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppIconTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - The icon set in the app

    /// The ten macOS entries (16 to 512 points, 1x and 2x), each a PNG of
    /// exactly that many pixels, in a catalog Xcode can read.
    func testTheIconSetHasTheTenMacEntries() throws {
        let entries = try Self.contentsEntries()

        XCTAssertEqual(entries.map { "\($0.size)@\($0.scale)x" }.sorted(),
                       ["128@1x", "128@2x", "16@1x", "16@2x", "256@1x", "256@2x", "32@1x", "32@2x",
                        "512@1x", "512@2x"])
        for entry in entries {
            XCTAssertEqual(entry.idiom, "mac", entry.filename)
            let size = try Self.pixelSize(of: Self.iconSet.appendingPathComponent(entry.filename))
            XCTAssertEqual(size.width, entry.size * entry.scale, entry.filename)
            XCTAssertEqual(size.height, entry.size * entry.scale, entry.filename)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: Self.repo.appendingPathComponent("App/Assets.xcassets/Contents.json").path))
    }

    // MARK: - The script

    /// Every entry of the icon set at its own size, and the preview, all
    /// listed; the colours are the tokens'.
    func testTheScriptDrawsEverySizeInTheTokensColours() throws {
        let design = try writeDesign(Self.tokens)
        let iconSet = folder.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
        let preview = folder.appendingPathComponent("preview.png")

        let run = try runMakeIcon(design: design, iconSet: iconSet, preview: preview)

        XCTAssertEqual(run.status, 0, run.err)
        let listed = run.out.split(separator: "\n").filter { $0.contains(".png") }
        XCTAssertEqual(listed.count, 11, run.out)
        for entry in try Self.contentsEntries() {
            XCTAssertTrue(run.out.contains(entry.filename), "\(entry.filename) is not listed")
            let size = try Self.pixelSize(of: iconSet.appendingPathComponent(entry.filename))
            XCTAssertEqual(size.width, entry.size * entry.scale, entry.filename)
            XCTAssertEqual(size.height, entry.size * entry.scale, entry.filename)
        }
        XCTAssertTrue(run.out.contains(preview.path), "the preview is not listed")
        let previewSize = try Self.pixelSize(of: preview)
        XCTAssertGreaterThan(previewSize.width, 1024 + 256 + 64 + 32 + 16)
        XCTAssertGreaterThan(previewSize.height, 2 * 1024)
    }

    /// The master: transparent outside the rounded square, `bg` inside it,
    /// and the waveform a line whose stroke runs from `spectrum-1` at its
    /// left end to `spectrum-6` at its right.
    func testTheMasterIsTheWaveformInTheSpectrumOnBg() throws {
        let design = try writeDesign(Self.tokens)
        let iconSet = folder.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
        let run = try runMakeIcon(design: design, iconSet: iconSet,
                                  preview: folder.appendingPathComponent("preview.png"))
        XCTAssertEqual(run.status, 0, run.err)
        let master = try Bitmap(contentsOf: iconSet.appendingPathComponent(Self.masterFile()))
        let bg = (r: 0x20, g: 0x28, b: 0x30)

        XCTAssertEqual(master.width, 1024)
        // Transparent outside the square, and at its corners, which are round.
        XCTAssertEqual(master.pixel(0, 0).a, 0)
        XCTAssertEqual(master.pixel(1023, 1023).a, 0)
        XCTAssertEqual(master.pixel(110, 110).a, 0, "the corner is square")
        XCTAssertEqual(master.pixel(913, 913).a, 0, "the corner is square")
        // `bg` inside it, away from the waveform: beside it and above it.
        XCTAssertTrue(master.pixel(150, 512).isOpaque(bg))
        XCTAssertTrue(master.pixel(512, 150).isOpaque(bg))
        XCTAssertTrue(master.pixel(492, 250).isOpaque(bg))

        // The line's left end is spectrum-1, its right end spectrum-6.
        XCTAssertTrue(master.pixel(212, 512).isNear(r: 0xFF, g: 0x00, b: 0x00),
                      "the left end is \(master.pixel(212, 512)), not spectrum-1")
        XCTAssertTrue(master.pixel(812, 512).isNear(r: 0x00, g: 0x00, b: 0xFF),
                      "the right end is \(master.pixel(812, 512)), not spectrum-6")
        // The tallest peak (point 7) is at x 492, y 302; the stroke is 24.
        let peak = try XCTUnwrap((100..<512).first { !master.pixel(492, $0).isOpaque(bg) })
        XCTAssertTrue((280...300).contains(peak), "the tallest peak starts at y \(peak)")

        // Every corner is where the design puts it, in the colour for its
        // distance along the line, not for its x.
        let heights: [Double] = [0, 0.25, -0.55, 0.35, -0.9, 0.6, -0.4, 1, -0.75, 0.3, -0.95, 0.55, -0.25, 0.45, -0.2, 0]
        let points = heights.enumerated().map { (x: 212 + 40 * Double($0), y: 512 - 210 * $1) }
        var travelled = [0.0]
        for (a, b) in zip(points, points.dropFirst()) { travelled.append(travelled.last! + hypot(b.x - a.x, b.y - a.y)) }
        let stops: [[Double]] = [[255, 0, 0], [255, 255, 0], [0, 255, 0], [0, 255, 255], [255, 0, 255], [0, 0, 255]]
        for index in 1..<15 {
            let x = travelled[index] / travelled.last! * 5
            let band = min(Int(x), 4)
            let mixed = zip(stops[band], stops[band + 1]).map { Int(($0 + ($1 - $0) * (x - Double(band))).rounded()) }
            let pixel = master.pixel(Int(points[index].x), Int(points[index].y.rounded()))
            XCTAssertTrue(pixel.isNear(r: mixed[0], g: mixed[1], b: mixed[2]),
                          "corner \(index) is \(pixel), not \(mixed)")
        }

        // The stroke is 24: beside the middle of the last segment, 9 from
        // its centre line is the line and 16 from it is bg.
        XCTAssertFalse(master.pixel(799, 539).isOpaque(bg), "the stroke is too thin")
        XCTAssertTrue(master.pixel(804, 544).isOpaque(bg), "the stroke is too thick")
    }

    /// At 16 px the line is widened to a pixel, so it still shows.
    func testTheSmallestSizeStillShowsTheLine() throws {
        let design = try writeDesign(Self.tokens)
        let iconSet = folder.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
        let run = try runMakeIcon(design: design, iconSet: iconSet,
                                  preview: folder.appendingPathComponent("preview.png"))
        XCTAssertEqual(run.status, 0, run.err)
        let small = try Bitmap(contentsOf: iconSet.appendingPathComponent("icon_16x16.png"))

        XCTAssertEqual(small.width, 16)
        let row = (0..<16).map { small.pixel($0, 8) }
        XCTAssertTrue(row.contains { abs($0.r - 0x20) >= 100 || abs($0.g - 0x28) >= 100 || abs($0.b - 0x30) >= 100 },
                      "row 8 of the 16 px icon is all near bg: \(row)")
    }

    /// Drift guard: the committed master is drawn in the colours DESIGN.md
    /// has now. If a token changes, this fails until `scripts/make-icon.swift`
    /// is run again.
    func testTheCommittedMasterMatchesTheCurrentTokens() throws {
        let design = try String(contentsOf: Self.repo.appendingPathComponent("DESIGN.md"), encoding: .utf8)
        func token(_ name: String) throws -> (r: Int, g: Int, b: Int) {
            let line = try XCTUnwrap(design.split(separator: "\n").first { $0.hasPrefix("  \(name): \"#") }, name)
            let hex = try XCTUnwrap(line.split(separator: "\"").dropFirst().first?.dropFirst(), name)
            let value = try XCTUnwrap(Int(hex, radix: 16), name)
            return (value >> 16, (value >> 8) & 0xFF, value & 0xFF)
        }
        let (bg, first, sixth) = (try token("bg"), try token("spectrum-1"), try token("spectrum-6"))
        let master = try Bitmap(contentsOf: Self.iconSet.appendingPathComponent(Self.masterFile()))

        XCTAssertTrue(master.pixel(150, 512).isOpaque(bg), "bg: \(master.pixel(150, 512))")
        XCTAssertTrue(master.pixel(212, 512).isNear(r: first.r, g: first.g, b: first.b),
                      "the left end is \(master.pixel(212, 512)), not spectrum-1")
        XCTAssertTrue(master.pixel(812, 512).isNear(r: sixth.r, g: sixth.g, b: sixth.b),
                      "the right end is \(master.pixel(812, 512)), not spectrum-6")
    }

    /// Any of the seven colours missing, or not a colour: the script names
    /// each one it cannot find and writes nothing.
    func testTheScriptStopsNamingEveryTokenItCannotFind() throws {
        var tokens = Self.tokens
        tokens["spectrum-4"] = nil
        tokens["bg"] = "{colors.text}"   // a reference, not a colour
        let design = try writeDesign(tokens)
        let iconSet = folder.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
        let preview = folder.appendingPathComponent("preview.png")

        let run = try runMakeIcon(design: design, iconSet: iconSet, preview: preview)

        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.err.contains("colors.spectrum-4"), run.err)
        XCTAssertTrue(run.err.contains("colors.bg"), run.err)
        XCTAssertFalse(run.err.contains("colors.spectrum-1"), run.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: iconSet.path), "it wrote the icon set")
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.path), "it wrote the preview")
    }

    // MARK: - Helpers

    private struct Entry: Decodable {
        let filename: String
        let idiom: String
        private let sizeText: String
        private let scaleText: String

        /// Points, from "16x16".
        var size: Int { Int(sizeText.split(separator: "x")[0]) ?? 0 }
        /// From "2x".
        var scale: Int { Int(scaleText.dropLast()) ?? 0 }

        private enum CodingKeys: String, CodingKey {
            case filename, idiom, sizeText = "size", scaleText = "scale"
        }
    }

    private struct Contents: Decodable {
        let images: [Entry]
    }

    private static func contentsEntries() throws -> [Entry] {
        let data = try Data(contentsOf: iconSet.appendingPathComponent("Contents.json"))
        return try JSONDecoder().decode(Contents.self, from: data).images
    }

    /// The 1024 px master, the `512x512@2x` entry.
    private static func masterFile() throws -> String {
        try XCTUnwrap(contentsEntries().first { $0.size == 512 && $0.scale == 2 }).filename
    }

    private static func pixelSize(of url: URL) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), url.path)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), url.path)
        return (image.width, image.height)
    }

    /// A DESIGN.md like the real one, with these colours in its front matter,
    /// and decoys outside it.
    private func writeDesign(_ colors: [String: String]) throws -> URL {
        let lines = colors.keys.sorted().map { "  \($0): \"\(colors[$0]!)\"" }
        let text = """
            ---
            version: alpha
            name: Test

            colors:
              text: "#F2F2F2"

            \(lines.joined(separator: "\n"))
            typography:
              title:
                fontFamily: "Jost"
            components:
              panel:
                backgroundColor: "#123456"
            ---

            ## Colors

            bg: "#FFFFFF"
            spectrum-4: "#FFFFFF"
            """
        let url = folder.appendingPathComponent("DESIGN.md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func runMakeIcon(design: URL, iconSet: URL, preview: URL) throws
        -> (status: Int32, out: String, err: String) {
        let out = folder.appendingPathComponent("stdout.txt")
        let err = folder.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = [Self.repo.appendingPathComponent("scripts/make-icon.swift").path,
                             "--design", design.path, "--iconset", iconSet.path, "--preview", preview.path]
        // Only what the Swift driver needs: none of the test runner's own
        // library paths.
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
        for name in ["DEVELOPER_DIR", "TMPDIR"] {
            environment[name] = ProcessInfo.processInfo.environment[name]
        }
        process.environment = environment
        process.standardOutput = try FileHandle(forWritingTo: out)
        process.standardError = try FileHandle(forWritingTo: err)
        try process.run()
        process.waitUntilExit()

        return (process.terminationStatus,
                try String(contentsOf: out, encoding: .utf8), try String(contentsOf: err, encoding: .utf8))
    }
}

/// A PNG's pixels as 8-bit sRGB, the top row first.
private struct Bitmap {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(contentsOf url: URL) throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), url.path)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), url.path)
        let (width, height) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn, url.path)
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    func pixel(_ x: Int, _ y: Int) -> Pixel {
        let i = (y * width + x) * 4
        return Pixel(r: Int(bytes[i]), g: Int(bytes[i + 1]), b: Int(bytes[i + 2]), a: Int(bytes[i + 3]))
    }
}

private struct Pixel: CustomStringConvertible {
    let r, g, b, a: Int

    func isOpaque(_ color: (r: Int, g: Int, b: Int)) -> Bool {
        a == 255 && r == color.r && g == color.g && b == color.b
    }

    /// Opaque and within a few steps of the colour: four pixels into a
    /// gradient that spans about a hundred, the blend has barely begun.
    func isNear(r: Int, g: Int, b: Int, within tolerance: Int = 16) -> Bool {
        a == 255 && abs(self.r - r) <= tolerance && abs(self.g - g) <= tolerance && abs(self.b - b) <= tolerance
    }

    var description: String { String(format: "#%02X%02X%02X alpha %d", r, g, b, a) }
}
