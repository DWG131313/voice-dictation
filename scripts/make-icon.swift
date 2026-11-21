// Draws VoiceDictation's app icon (Danny's design, 2026-11-20; D7).
//
// A black rounded square and, on it, a sharp-cornered waveform whose stroke
// is the spectrum, running along the line: red at its left end to violet at
// its right. The waveform is the only element: no glow, no shadow, no text,
// no other colour. The seven colours are DESIGN.md's tokens (`bg` and `spectrum-1` to
// `spectrum-6`), read from its front matter, so the icon follows them. Every
// size is drawn from the same paths at that size, never by shrinking the
// 1024 px master.
//
// Run from the repo root:
//
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift scripts/make-icon.swift
//
// It writes the ten PNGs that App/Assets.xcassets/AppIcon.appiconset's
// Contents.json names, and docs/icon-preview.png (the master beside the 256,
// 64, 32 and 16 px renders, each at its real size, on black and on mid-grey),
// and lists the eleven. The tests point it elsewhere:
//
//   --design <DESIGN.md>   --iconset <folder>   --preview <file.png>

import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Where things are

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
var designFile = repo.appendingPathComponent("DESIGN.md")
var iconSetFolder = repo.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
var previewFile = repo.appendingPathComponent("docs/icon-preview.png")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let option = arguments.removeFirst()
    guard !arguments.isEmpty else { fail("\(option) needs a value") }
    let value = URL(fileURLWithPath: arguments.removeFirst())
    switch option {
    case "--design": designFile = value
    case "--iconset": iconSetFolder = value
    case "--preview": previewFile = value
    default: fail("unknown option \(option); the options are --design, --iconset and --preview")
    }
}

// MARK: - The colours, from DESIGN.md

/// The `colors:` map of DESIGN.md's YAML front matter: each name and its
/// value, quotes removed.
func frontMatterColors(of text: String) -> [String: String] {
    let lines = text.components(separatedBy: .newlines)
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
          let end = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" })
    else { return [:] }

    var colors: [String: String] = [:]
    var inColors = false
    for line in lines[1..<end] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        guard line.hasPrefix(" ") || line.hasPrefix("\t") else {
            // A top-level key: `colors:` opens the map, any other closes it.
            inColors = trimmed == "colors:"
            continue
        }
        guard inColors, let colon = trimmed.firstIndex(of: ":") else { continue }
        let name = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
        var value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if let quote = value.first, quote == "\"" || quote == "'" {
            value = String(value.dropFirst().prefix { $0 != quote })
        }
        colors[name] = value
    }
    return colors
}

/// "#RRGGBB" as an sRGB colour; nil for anything else, a reference included.
func color(_ hex: String) -> CGColor? {
    let digits = hex.dropFirst()
    guard hex.first == "#", digits.count == 6, digits.allSatisfy(\.isHexDigit),
          let value = UInt32(digits, radix: 16)
    else { return nil }
    return CGColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                   blue: CGFloat(value & 0xFF) / 255, alpha: 1)
}

guard let designText = try? String(contentsOf: designFile, encoding: .utf8) else {
    fail("cannot read \(designFile.path)")
}
let written = frontMatterColors(of: designText)
let tokenNames = ["bg"] + (1...6).map { "spectrum-\($0)" }
let tokens = tokenNames.reduce(into: [String: CGColor]()) { found, name in
    found[name] = written[name].flatMap(color)
}
let missing = tokenNames.filter { tokens[$0] == nil }
guard missing.isEmpty else {
    fail("\(designFile.path) has no #RRGGBB colour in its front matter for "
         + missing.map { "colors.\($0)" }.joined(separator: ", ") + ". Nothing was written.")
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let bg = tokens["bg"]!
/// The six bands spread evenly from the first stop to the last and blended
/// linearly in sRGB, as `Theme.Color.spectrum`'s `LinearGradient` blends them.
let bands: [[CGFloat]] = (1...6).map { tokens["spectrum-\($0)"]!.components! }

/// The spectrum's colour at `t`, 0 at its first band to 1 at its last.
func spectrumColor(at t: CGFloat) -> CGColor {
    let x = min(max(t, 0), 1) * CGFloat(bands.count - 1)
    let i = min(Int(x), bands.count - 2)
    let f = x - CGFloat(i)
    let mixed = zip(bands[i], bands[i + 1]).map { $0 + ($1 - $0) * f }
    return CGColor(colorSpace: srgb, components: mixed)!
}

/// The part of the spectrum from `t0` to `t1` as a gradient of its own: a
/// stop at each end and at every band between them, so it blends as the
/// whole spectrum does.
func spectrumGradient(from t0: CGFloat, to t1: CGFloat) -> CGGradient {
    let inner = (0..<bands.count).map { CGFloat($0) / CGFloat(bands.count - 1) }.filter { $0 > t0 && $0 < t1 }
    let stops = [t0] + inner + [t1]
    return CGGradient(colorsSpace: srgb, colors: stops.map(spectrumColor(at:)) as CFArray,
                      locations: stops.map { ($0 - t0) / (t1 - t0) })!
}

// MARK: - The drawing: a 1024-point space with y down, the master's pixels

let canvas: CGFloat = 1024

/// The black rounded square on the standard macOS grid: 824 wide, centred,
/// with continuous corners of radius 185. The canvas stays transparent
/// outside it: since macOS 26 an icon whose pixels leave the system's icon
/// shape goes on a grey plate.
let square = RoundedRectangle(cornerRadius: 185, style: .continuous)
    .path(in: CGRect(x: 100, y: 100, width: 824, height: 824)).cgPath

/// The stroke is 24 at 1024, about 1.5 px in the Dock. At the small sizes it
/// widens so that the line is never under a pixel.
func strokeWidth(pixels: Int) -> CGFloat {
    max(24, canvas / CGFloat(pixels))
}

// The waveform, as the centre line its stroke straddles: sixteen points
// evenly spaced across 600, joined by straight segments, each peak and
// valley at its own height (up is positive, 1 is 210 above the middle).
let heights: [CGFloat] = [0, 0.25, -0.55, 0.35, -0.9, 0.6, -0.4, 1, -0.75, 0.3, -0.95, 0.55, -0.25, 0.45, -0.2, 0]
let wave: [CGPoint] = heights.enumerated().map { index, height in
    CGPoint(x: 212 + 40 * CGFloat(index), y: 512 - 210 * height)
}

/// How far along the line each point is, 0 at the first to 1 at the last:
/// the spectrum runs along the line by distance travelled.
let progress: [CGFloat] = {
    var travelled: [CGFloat] = [0]
    for (a, b) in zip(wave, wave.dropFirst()) {
        travelled.append(travelled.last! + hypot(b.x - a.x, b.y - a.y))
    }
    return travelled.map { $0 / travelled.last! }
}()

/// Clips to one side of the bisector of the corner at `corner`, whose arms
/// run to `a` and `b`: the side `kept` is on.
func clipToSide(of corner: CGPoint, between a: CGPoint, and b: CGPoint, keeping kept: CGPoint, in context: CGContext) {
    func unit(_ p: CGPoint) -> CGPoint {
        let length = hypot(p.x - corner.x, p.y - corner.y)
        return CGPoint(x: (p.x - corner.x) / length, y: (p.y - corner.y) / length)
    }
    let (ua, ub) = (unit(a), unit(b))
    let along = CGPoint(x: ua.x + ub.x, y: ua.y + ub.y)
    let size = hypot(along.x, along.y)
    guard size > 0.001 else { return }   // a straight line has no corner to share
    let bisector = CGPoint(x: along.x / size, y: along.y / size)
    var normal = CGPoint(x: -bisector.y, y: bisector.x)
    let k = unit(kept)
    if normal.x * k.x + normal.y * k.y < 0 { normal = CGPoint(x: -normal.x, y: -normal.y) }
    let far = 4 * canvas
    let p1 = CGPoint(x: corner.x - far * bisector.x, y: corner.y - far * bisector.y)
    let p2 = CGPoint(x: corner.x + far * bisector.x, y: corner.y + far * bisector.y)
    context.beginPath()
    context.move(to: p1)
    context.addLine(to: p2)
    context.addLine(to: CGPoint(x: p2.x + far * normal.x, y: p2.y + far * normal.y))
    context.addLine(to: CGPoint(x: p1.x + far * normal.x, y: p1.y + far * normal.y))
    context.closePath()
    context.clip()
}

func makeContext(width: Int, height: Int) -> CGContext {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("cannot make a \(width) × \(height) px drawing") }
    return context
}

/// The icon at `pixels` × `pixels`: the same paths, scaled to that size.
func render(pixels: Int) -> CGImage {
    let context = makeContext(width: pixels, height: pixels)
    let scale = CGFloat(pixels) / canvas
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: scale, y: -scale)

    context.addPath(square)
    context.setFillColor(bg)
    context.fillPath()

    // Core Graphics has no gradient along a path, so each straight segment
    // is its own: its stroke, round at both ends, becomes a clip, and its
    // part of the spectrum is drawn through it along the segment. At a
    // corner the two strokes overlap, so each is also clipped to its own
    // side of the corner's bisector: they meet in a mitre, neither painted
    // over the other.
    context.setLineWidth(strokeWidth(pixels: pixels))
    context.setLineCap(.round)
    for index in wave.indices.dropLast() {
        context.saveGState()
        context.move(to: wave[index])
        context.addLine(to: wave[index + 1])
        context.replacePathWithStrokedPath()
        context.clip()
        if index > 0 {
            clipToSide(of: wave[index], between: wave[index - 1], and: wave[index + 1], keeping: wave[index + 1], in: context)
        }
        if index + 2 < wave.count {
            clipToSide(of: wave[index + 1], between: wave[index], and: wave[index + 2], keeping: wave[index], in: context)
        }
        context.drawLinearGradient(spectrumGradient(from: progress[index], to: progress[index + 1]),
                                   start: wave[index], end: wave[index + 1],
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    guard let image = context.makeImage() else { fail("cannot finish the \(pixels) px drawing") }
    return image
}

// MARK: - The files

/// AppIcon.appiconset's ten macOS entries, named as its Contents.json names
/// them: 16 to 512 points, at 1x and 2x.
let entries: [(file: String, pixels: Int)] = [16, 32, 128, 256, 512].flatMap { points in
    [("icon_\(points)x\(points).png", points), ("icon_\(points)x\(points)@2x.png", 2 * points)]
}
let renders = Dictionary(uniqueKeysWithValues: Set(entries.map(\.pixels)).map { ($0, render(pixels: $0)) })

/// The master beside the 256, 64, 32 and 16 px renders, each at its real
/// size, on black above and on mid-grey below.
func preview() -> CGImage {
    let sizes = [1024, 256, 64, 32, 16]
    let margin = 64
    let width = sizes.reduce(margin) { $0 + $1 + margin }
    let rowHeight = 1024 + 2 * margin
    let backdrops = [CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
                     CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)]
    let context = makeContext(width: width, height: rowHeight * backdrops.count)
    context.interpolationQuality = .none
    for (row, backdrop) in backdrops.enumerated() {
        // Core Graphics counts rows up from the bottom; the first backdrop is on top.
        let rowY = (backdrops.count - 1 - row) * rowHeight
        context.setFillColor(backdrop)
        context.fill(CGRect(x: 0, y: rowY, width: width, height: rowHeight))
        var x = margin
        for size in sizes {
            context.draw(renders[size]!, in: CGRect(x: x, y: rowY + (rowHeight - size) / 2, width: size, height: size))
            x += size + margin
        }
    }
    guard let image = context.makeImage() else { fail("cannot finish the preview") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("cannot write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
}

/// A path as typed from the repo root when it is inside the repo.
func shown(_ url: URL) -> String {
    let root = repo.path + "/"
    return url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count)) : url.path
}

let previewImage = preview()
do {
    try FileManager.default.createDirectory(at: iconSetFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: previewFile.deletingLastPathComponent(), withIntermediateDirectories: true)
} catch {
    fail("cannot make a folder for the PNGs: \(error.localizedDescription)")
}
for entry in entries {
    writePNG(renders[entry.pixels]!, to: iconSetFolder.appendingPathComponent(entry.file))
}
writePNG(previewImage, to: previewFile)

print("make-icon: wrote \(entries.count + 1) PNGs")
for entry in entries {
    print("  \(shown(iconSetFolder.appendingPathComponent(entry.file)))  \(entry.pixels) px")
}
print("  \(shown(previewFile))  \(previewImage.width) × \(previewImage.height) px")
