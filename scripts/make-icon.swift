// Draws VoiceDictation's app icon (Task 26; Danny's design, D7).
//
// A black rounded square and, on it, a microphone drawn as an outline whose
// stroke is the spectrum: red at the top of the head to violet at the base.
// The microphone is the only element: no glow, no shadow, no text, no other
// colour. The seven colours are DESIGN.md's tokens (`bg` and `spectrum-1` to
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
let spectrum = CGGradient(colorsSpace: srgb,
                          colors: (1...6).map { tokens["spectrum-\($0)"]! } as CFArray,
                          locations: (0...5).map { CGFloat($0) / 5 })!

// MARK: - The drawing: a 1024-point space with y down, the master's pixels

let canvas: CGFloat = 1024

/// The black rounded square on the standard macOS grid: 824 wide, centred,
/// with continuous corners of radius 185. The canvas stays transparent
/// outside it: since macOS 26 an icon whose pixels leave the system's icon
/// shape goes on a grey plate.
let square = RoundedRectangle(cornerRadius: 185, style: .continuous)
    .path(in: CGRect(x: 100, y: 100, width: 824, height: 824)).cgPath

/// One stroke width throughout: 44 at 1024, so it still reads at 32 px.
let stroke: CGFloat = 44

// The microphone, as the centre lines its stroke straddles: a capsule head, a
// U-shaped holder around its lower end, a stem and a base. Centred, it is 504
// tall with its stroke, 61% of the square.
let centre: CGFloat = 512
let headRadius: CGFloat = 80
let headTop: CGFloat = 282
let headBottom: CGFloat = 562
/// The head's lower curve and the U share a centre; a gap of 36 between them.
let holderCentre = headBottom - headRadius
let holderRadius = headRadius + stroke + 36
/// The U's arms end beside the middle of the head.
let holderTop = holderCentre - 60
let baseY: CGFloat = 742
let baseHalfWidth: CGFloat = 100

let microphone: CGPath = {
    let path = CGMutablePath()
    path.addRoundedRect(in: CGRect(x: centre - headRadius, y: headTop,
                                   width: 2 * headRadius, height: headBottom - headTop),
                        cornerWidth: headRadius, cornerHeight: headRadius)
    // Down the left arm, round the bottom (through angle π/2, which is down
    // here), up the right arm.
    path.move(to: CGPoint(x: centre - holderRadius, y: holderTop))
    path.addLine(to: CGPoint(x: centre - holderRadius, y: holderCentre))
    path.addRelativeArc(center: CGPoint(x: centre, y: holderCentre), radius: holderRadius,
                        startAngle: .pi, delta: -.pi)
    path.addLine(to: CGPoint(x: centre + holderRadius, y: holderTop))
    path.move(to: CGPoint(x: centre, y: holderCentre + holderRadius))
    path.addLine(to: CGPoint(x: centre, y: baseY))
    path.move(to: CGPoint(x: centre - baseHalfWidth, y: baseY))
    path.addLine(to: CGPoint(x: centre + baseHalfWidth, y: baseY))
    return path
}()

/// The spectrum runs from the top of the head's stroke to the bottom of the base's.
let spectrumStart = CGPoint(x: centre, y: headTop - stroke / 2)
let spectrumEnd = CGPoint(x: centre, y: baseY + stroke / 2)

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

    // Stroke the microphone, turn the stroke into a clip, and draw the
    // spectrum through it.
    context.addPath(microphone)
    context.setLineWidth(stroke)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.replacePathWithStrokedPath()
    context.clip()
    context.drawLinearGradient(spectrum, start: spectrumStart, end: spectrumEnd,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

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
