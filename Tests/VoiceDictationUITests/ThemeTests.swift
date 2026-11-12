import AppKit
import SwiftUI
import XCTest
@testable import VoiceDictationUI

final class ThemeTests: XCTestCase {
    private func hex(_ color: SwiftUI.Color) -> String {
        let c = NSColor(color).usingColorSpace(.sRGB)!
        func b(_ v: CGFloat) -> Int { Int((v * 255).rounded()) }
        return String(format: "#%02X%02X%02X", b(c.redComponent), b(c.greenComponent), b(c.blueComponent))
    }

    func testFontsRegister() {
        Fonts.registerAll()
        XCTAssertNotNil(NSFont(name: "Jost-Regular", size: 12))
        XCTAssertNotNil(NSFont(name: "WorkSans-Regular", size: 12))
        XCTAssertNotNil(NSFont(name: "DMMono-Regular", size: 12))
    }

    func testTokenValues() {
        XCTAssertEqual(hex(Theme.Color.bg), "#000000")
        XCTAssertEqual(hex(Theme.Color.bgElevated), "#0A0A0A")
        XCTAssertEqual(hex(Theme.Color.text), "#F2F2F2")
        XCTAssertEqual(hex(Theme.Color.textMuted), "#8C8C8C")
        XCTAssertEqual(hex(Theme.Color.hairline), "#2A2A2A")
    }

    func testSpectrumHasSixStops() {
        XCTAssertEqual(Theme.Color.spectrumStops.map(hex),
                       ["#FF2D1F", "#FF8A00", "#FFE600", "#27D14B", "#1E8BFF", "#7B3DFF"])
    }

    func testSpaceScale() {
        XCTAssertEqual([Theme.Space.xs, Theme.Space.sm, Theme.Space.md, Theme.Space.lg, Theme.Space.xl],
                       [4, 8, 16, 24, 40])
    }

    private func width(_ font: CTFont) -> CGFloat {
        let str = NSAttributedString(string: "Hamburgefonts", attributes: [.font: font])
        return str.size().width
    }

    func testVariableWeightsAreDistinct() {
        Fonts.registerAll()
        for name in ["Jost-Regular", "WorkSans-Regular"] {
            let regular = width(Fonts.face(name, size: 40, weight: 400))
            let medium = width(Fonts.face(name, size: 40, weight: 500))
            let semibold = width(Fonts.face(name, size: 40, weight: 600))
            XCTAssertNotEqual(regular, medium, name)
            XCTAssertNotEqual(medium, semibold, name)
        }
    }

    func testThemeFontsUseTheRealWeights() {
        Fonts.registerAll()
        XCTAssertNotEqual(width(Theme.Font.titleFace(26)), width(Fonts.face("Jost-Regular", size: 26, weight: 400)))
        XCTAssertNotEqual(width(Theme.Font.uiFace(26, medium: true)), width(Theme.Font.uiFace(26)))
    }
}
