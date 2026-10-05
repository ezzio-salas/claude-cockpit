import AppKit
import CockpitCore

enum Theme {
    enum DisplayWeight: String {
        case medium = "Orbitron-Medium"
        case bold = "Orbitron-Bold"
    }

    static let cyan = NSColor(srgbRed: 0.31, green: 0.91, blue: 1.0, alpha: 1)
    static let amber = NSColor(srgbRed: 1.0, green: 0.72, blue: 0.24, alpha: 1)
    static let red = NSColor(srgbRed: 1.0, green: 0.33, blue: 0.38, alpha: 1)
    static let primaryText = NSColor(white: 1, alpha: 0.78)
    static let secondaryText = NSColor(white: 1, alpha: 0.42)

    static func color(for severity: UsageMeter.Severity) -> NSColor {
        switch severity {
        case .normal: return cyan
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
