import Foundation

/// How much of the Cursor plan has been used, as the Cursor CLI's `/usage` screen reports it.
public struct CursorUsage: Equatable, Sendable {
    /// One share of the plan, such as `Included` or `Auto`.
    public struct Allowance: Equatable, Sendable {
        public let label: String
        public let percentUsed: Int

        public init(label: String, percentUsed: Int) {
            self.label = label
            self.percentUsed = percentUsed
        }
    }

    public let allowances: [Allowance]
    /// The day the plan renews, in the CLI's words (`Oct 17`); nil when it names none.
    public let resets: String?
    /// Spend beyond the plan, in the CLI's words (`$482.19`); nil when it shows none.
    public let onDemand: String?

    public init(allowances: [Allowance], resets: String?, onDemand: String?) {
        self.allowances = allowances
        self.resets = resets
        self.onDemand = onDemand
    }
}

public enum CursorUsageParser {
    /// Reads the `/usage` table out of what the CLI drew, or nil if it is not there.
    ///
    /// The screen is a stream of redraws rather than lines, so a row can appear more than once;
    /// the last drawing of each wins, in the order the rows first appeared.
    public static func parse(_ screen: String) -> CursorUsage? {
        let text = plainText(screen)

        var allowances: [CursorUsage.Allowance] = []
        for match in text.matches(of: #/([A-Za-z][A-Za-z-]*)\s+(\d{1,3})% used/#) {
            let allowance = CursorUsage.Allowance(
                label: match.1.uppercased(), percentUsed: min(Int(match.2) ?? 0, 100)
            )
            if let drawnBefore = allowances.firstIndex(where: { $0.label == allowance.label }) {
                allowances[drawnBefore] = allowance
            } else {
                allowances.append(allowance)
            }
        }
        let onDemand = text.matches(of: #/On-Demand\s+(\$[\d,]+(?:\.\d+)?)/#).last.map { String($0.1) }
        guard !allowances.isEmpty || onDemand != nil else { return nil }

        let resets = text.matches(of: #/Resets\s+([A-Z][a-z]{2} \d{1,2})\b/#).last.map { String($0.1) }
        return CursorUsage(allowances: allowances, resets: resets, onDemand: onDemand)
    }

    /// `screen` with its terminal escape sequences replaced by spaces.
    static func plainText(_ screen: String) -> String {
        // CSI, OSC, character-set and two-character escape sequences. Matched by scalar, because a
        // carriage return and line feed drawn together are one character and would hide either.
        let escape = #/\u{1B}(?:\[[0-?]*[ -\/]*[@-~]|\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\)|[()][0-9A-Za-z]|[@-Z\\-_=>])/#
            .matchingSemantics(.unicodeScalar)
        return screen.replacing(escape, with: " ")
    }
}
