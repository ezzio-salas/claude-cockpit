import Foundation

/// One usage limit as reported by Claude's `/usage` command.
public struct UsageMeter: Equatable {
    public enum Reset: Equatable {
        case at(Date)
        /// Reset text in a form the parser does not recognize, kept verbatim for display.
        case unparsed(String)
    }

    public enum Severity: Equatable {
        case normal
        case elevated
        case critical

        public init(percentUsed: Int) {
            switch percentUsed {
            case ..<70: self = .normal
            case ..<90: self = .elevated
            default: self = .critical
            }
        }
    }

    public let label: String
    public let percentUsed: Int
    public let reset: Reset

    public init(label: String, percentUsed: Int, reset: Reset) {
        self.label = label
        self.percentUsed = percentUsed
        self.reset = reset
    }

    public var severity: Severity {
        Severity(percentUsed: percentUsed)
    }
}
