import CoreText
import Foundation

/// Registers the bundled Jost, Work Sans and DM Mono for this process.
/// Call once at launch; calling it again is harmless.
public enum Fonts {
    private static let files = ["Jost-Variable", "WorkSans-Variable", "DMMono-Regular"]

    public static func registerAll() {
        for name in files {
            guard let url = Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") else {
                continue
            }
            // Already-registered is reported as an error and is fine.
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
