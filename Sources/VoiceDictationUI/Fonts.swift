import CoreText
import AppKit
import Foundation

/// Registers the bundled Jost, Work Sans and DM Mono for this process.
/// Call once at launch; calling it again is harmless.
public enum Fonts {
    private static let files = ["Jost-Variable", "WorkSans-Variable", "DMMono-Regular"]

    /// How many times `registerAll()` has run (lets a test see the launch wiring).
    nonisolated(unsafe) static private(set) var registerCalls = 0

    @discardableResult
    public static func registerAll() -> Bool {
        registerCalls += 1
        var allFound = true
        for name in files {
            guard let url = Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") else {
                assertionFailure("Missing bundled font: \(name).ttf")
                allFound = false
                continue
            }
            // Already-registered is reported as an error and is fine.
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return allFound
    }

    /// The 'wght' axis identifier of a variable font.
    private static let weightAxis = NSNumber(value: 0x7767_6874)

    /// A face at a weight on the font's variable axis (400 regular, 500 medium,
    /// 600 semibold). A descriptor weight trait does not move the axis, so the
    /// variation is set explicitly.
    static func face(_ postScriptName: String, size: CGFloat, weight: CGFloat) -> CTFont {
        let attrs: [CFString: Any] = [
            kCTFontNameAttribute: postScriptName,
            kCTFontVariationAttribute: [weightAxis: weight],
        ]
        return CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attrs as CFDictionary), size, nil)
    }
}
