import Foundation

/// An opaque sRGB color that reads and writes itself as `#RRGGBB`.
public struct HexColor: Equatable, Sendable {
    /// The widget's standard accent.
    public static let cockpitCyan = HexColor(red: 0.31, green: 0.91, blue: 1.0)

    public let red: Double
    public let green: Double
    public let blue: Double

    /// Components are clamped to 0...1 and rounded to the nearest of the 256 levels hex can express.
    public init(red: Double, green: Double, blue: Double) {
        func level(_ component: Double) -> Double {
            (min(max(component, 0), 1) * 255).rounded() / 255
        }
        self.red = level(red)
        self.green = level(green)
        self.blue = level(blue)
    }

    public init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.wholeMatch(of: #/#?([0-9A-Fa-f]{6})/#),
              let value = Int(match.1, radix: 16)
        else { return nil }
        self.init(
            red: Double(value >> 16 & 0xFF) / 255,
            green: Double(value >> 8 & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    public var hex: String {
        func level(_ component: Double) -> Int {
            Int((component * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", level(red), level(green), level(blue))
    }
}

/// The parts of the widget's look a person can make their own.
public struct CockpitAppearance: Equatable, Sendable {
    public static let defaultTitle = "CLAUDE"
    /// The longest title that leaves room for the status note beside it.
    public static let maximumTitleLength = 14
    public static let standard = CockpitAppearance(
        title: defaultTitle, accent: .cockpitCyan, border: .cockpitCyan, glow: .cockpitCyan
    )

    public let title: String
    /// Colors the section titles, the figures, and meters that are below the warning levels.
    public let accent: HexColor
    public let border: HexColor
    public let glow: HexColor

    public init(title: String, accent: HexColor, border: HexColor, glow: HexColor) {
        self.title = Self.normalizedTitle(title)
        self.accent = accent
        self.border = border
        self.glow = glow
    }

    /// Titles are shown like every other label: trimmed and in capitals. A blank title means the default.
    public static func normalizedTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultTitle }
        return String(trimmed.uppercased().prefix(maximumTitleLength))
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Keeps the chosen appearance in user defaults, in a form that can also be set from the command line.
public struct AppearanceStore {
    private enum Key {
        static let title = "title"
        static let accent = "accentColor"
        static let border = "borderColor"
        static let glow = "glowColor"
        static let offered = "hasOfferedCustomization"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var appearance: CockpitAppearance {
        get {
            CockpitAppearance(
                title: defaults.string(forKey: Key.title) ?? CockpitAppearance.defaultTitle,
                accent: color(forKey: Key.accent),
                border: color(forKey: Key.border),
                glow: color(forKey: Key.glow)
            )
        }
        nonmutating set {
            defaults.set(newValue.title, forKey: Key.title)
            defaults.set(newValue.accent.hex, forKey: Key.accent)
            defaults.set(newValue.border.hex, forKey: Key.border)
            defaults.set(newValue.glow.hex, forKey: Key.glow)
        }
    }

    /// Whether the person has already been shown the personalize window once.
    public var hasOfferedCustomization: Bool {
        get { defaults.bool(forKey: Key.offered) }
        nonmutating set { defaults.set(newValue, forKey: Key.offered) }
    }

    public func reset() {
        [Key.title, Key.accent, Key.border, Key.glow].forEach(defaults.removeObject(forKey:))
    }

    private func color(forKey key: String) -> HexColor {
        defaults.string(forKey: key).flatMap(HexColor.init(hex:)) ?? .cockpitCyan
    }
}
