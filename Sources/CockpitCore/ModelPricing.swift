import Foundation

/// Anthropic API list prices, in US dollars per million tokens.
public struct TokenRates: Equatable, Sendable {
    public let input: Double
    public let output: Double
    public let cacheWrite5Minutes: Double
    public let cacheWrite1Hour: Double
    public let cacheRead: Double

    /// Cache prices at the usual multiples of the input price: 1.25x and 2x to write, 0.1x to read.
    static func standard(input: Double, output: Double) -> TokenRates {
        TokenRates(
            input: input,
            output: output,
            cacheWrite5Minutes: input * 1.25,
            cacheWrite1Hour: input * 2,
            cacheRead: input * 0.1
        )
    }
}

public enum ModelPricing {
    /// Standard-speed prices as published in September 2026.
    /// Update this table when Anthropic changes a price or releases a model.
    private static let table: [String: TokenRates] = [
        "claude-fable-5-1": TokenRates(
            input: 10, output: 50, cacheWrite5Minutes: 12.50, cacheWrite1Hour: 20, cacheRead: 0.25
        ),
        "claude-fable-5": .standard(input: 10, output: 50),
        "claude-opus-5-5": TokenRates(
            input: 4, output: 20, cacheWrite5Minutes: 5, cacheWrite1Hour: 8, cacheRead: 0.20
        ),
        "claude-opus-5": .standard(input: 5, output: 25),
        "claude-opus-4-8": .standard(input: 5, output: 25),
        "claude-opus-4-7": .standard(input: 5, output: 25),
        "claude-opus-4-6": .standard(input: 5, output: 25),
        "claude-sonnet-5-5": TokenRates(
            input: 2, output: 10, cacheWrite5Minutes: 2.50, cacheWrite1Hour: 4, cacheRead: 0.20
        ),
        "claude-sonnet-5": TokenRates(
            input: 2, output: 10, cacheWrite5Minutes: 2.50, cacheWrite1Hour: 4, cacheRead: 0.20
        ),
        "claude-sonnet-4-6": .standard(input: 3, output: 15),
        "claude-haiku-4-5": .standard(input: 1, output: 5),
    ]

    /// Returns nil for a model with no known price, so callers can report it instead of guessing.
    public static func rates(for model: String) -> TokenRates? {
        if let exact = table[model] {
            return exact
        }
        // A dated snapshot such as `claude-haiku-4-5-20251001` is priced as its base model.
        guard let snapshot = model.wholeMatch(of: #/(.+)-\d{8}/#) else { return nil }
        return table[String(snapshot.1)]
    }
}
