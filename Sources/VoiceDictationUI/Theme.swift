import SwiftUI

/// Prism design tokens (see DESIGN.md). Dark only, radius 0, no shadows.
public enum Theme {
    public enum Color {
        public static let bg = SwiftUI.Color(red: 0, green: 0, blue: 0)
        public static let bgElevated = SwiftUI.Color(red: 10 / 255, green: 10 / 255, blue: 10 / 255)
        public static let text = SwiftUI.Color(red: 242 / 255, green: 242 / 255, blue: 242 / 255)
        public static let textMuted = SwiftUI.Color(red: 140 / 255, green: 140 / 255, blue: 140 / 255)
        public static let hairline = SwiftUI.Color(red: 42 / 255, green: 42 / 255, blue: 42 / 255)

        /// The six spectrum bands, no indigo. Used once per screen, never in the indicator.
        public static let spectrumStops: [SwiftUI.Color] = [
            (0xFF, 0x2D, 0x1F), (0xFF, 0x8A, 0x00), (0xFF, 0xE6, 0x00),
            (0x27, 0xD1, 0x4B), (0x1E, 0x8B, 0xFF), (0x7B, 0x3D, 0xFF),
        ].map { SwiftUI.Color(red: Double($0.0) / 255, green: Double($0.1) / 255, blue: Double($0.2) / 255) }

        public static let spectrum = LinearGradient(
            colors: spectrumStops, startPoint: .leading, endPoint: .trailing)
    }

    public enum Font {
        /// Jost 600, one title per screen.
        public static func title(_ size: CGFloat = 26) -> SwiftUI.Font {
            .custom("Jost-Regular", size: size).weight(.semibold)
        }

        /// Work Sans 400, or 500 when `medium`.
        public static func ui(_ size: CGFloat = 14, medium: Bool = false) -> SwiftUI.Font {
            .custom("WorkSans-Regular", size: size).weight(medium ? .medium : .regular)
        }

        /// DM Mono, for times and figures.
        public static func mono(_ size: CGFloat = 12) -> SwiftUI.Font {
            .custom("DMMono-Regular", size: size)
        }
    }

    public enum Space {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 24
        public static let xl: CGFloat = 40
    }
}

/// Primary button: white fill, black Jost label, square corners.
private struct PrismPrimaryButton: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .font(Theme.Font.title(14))
            .foregroundStyle(Theme.Color.bg)
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
            .background(Rectangle().fill(SwiftUI.Color.white))
    }
}

/// Secondary button: 1px white outline, white label, square corners.
private struct PrismSecondaryButton: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .font(Theme.Font.ui(14, medium: true))
            .foregroundStyle(SwiftUI.Color.white)
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
            .overlay(Rectangle().strokeBorder(SwiftUI.Color.white, lineWidth: 1))
    }
}

public extension View {
    func prismPrimaryButton() -> some View { modifier(PrismPrimaryButton()) }
    func prismSecondaryButton() -> some View { modifier(PrismSecondaryButton()) }
}

/// The spectrum, 2px: the one colour on a screen, under the selected transcript.
public struct SpectrumUnderline: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(Theme.Color.spectrum)
            .frame(height: 2)
            .accessibilityHidden(true)
    }
}
