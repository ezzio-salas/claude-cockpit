import AppKit
import CockpitCore

extension NSColor {
    convenience init(_ color: HexColor) {
        self.init(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    }

    /// The nearest opaque sRGB color, or nil for a color that has no RGB form, such as a pattern.
    var hexColor: HexColor? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        return HexColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
    }
}

enum Theme {
    enum DisplayWeight: String {
        case medium = "Orbitron-Medium"
        case bold = "Orbitron-Bold"
    }

    static let amber = NSColor(srgbRed: 1.0, green: 0.72, blue: 0.24, alpha: 1)
    static let red = NSColor(srgbRed: 1.0, green: 0.33, blue: 0.38, alpha: 1)
    static let primaryText = NSColor(white: 1, alpha: 0.78)
    static let secondaryText = NSColor(white: 1, alpha: 0.42)

    /// Warning levels keep their own colors whatever accent is chosen, because the color is the warning.
    static func color(for severity: UsageMeter.Severity, accent: NSColor) -> NSColor {
        switch severity {
        case .normal: return accent
        case .elevated: return amber
        case .critical: return red
        }
    }

    /// Registers the bundled Orbitron font. Outside an app bundle (`swift run`) there is none and
    /// `displayFont` falls back to the system monospaced font.
    static func registerFonts() {
        guard let url = Bundle.main.url(forResource: "Orbitron", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static func displayFont(size: CGFloat, weight: DisplayWeight = .medium) -> NSFont {
        NSFont(name: weight.rawValue, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: weight == .bold ? .bold : .medium)
    }

    static func text(_ string: String, font: NSFont, color: NSColor, kern: CGFloat = 0) -> NSAttributedString {
        let singleLine = NSMutableParagraphStyle()
        singleLine.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: color, .kern: kern, .paragraphStyle: singleLine,
        ])
    }
}
