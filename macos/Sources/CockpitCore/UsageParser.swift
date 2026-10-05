import Foundation

/// Extracts usage meters from the plain-text output of `claude -p "/usage"`.
public enum UsageParser {
    private static let monthAbbreviations = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
    ]

    /// Returns one meter per `Current <name>: <N>% used · resets <when>` line, in output order.
    public static func parse(_ text: String, now: Date) -> [UsageMeter] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let match = trimmed.wholeMatch(of: #/Current (.+?): (\d+)% used · resets (.+)/#),
                  let percent = Int(match.2)
            else { return nil }
            return UsageMeter(
                label: label(for: String(match.1)),
                percentUsed: min(percent, 100),
                reset: reset(from: String(match.3), now: now)
            )
        }
    }

    private static func label(for name: String) -> String {
        switch name.lowercased() {
        case "session":
            return "SESSION"
        case "week (all models)":
            return "WEEK"
        default:
            if let match = name.wholeMatch(of: #/week \((.+)\)/#.ignoresCase()) {
                return "WEEK · \(match.1.uppercased())"
            }
            return name.uppercased()
        }
    }

    /// Parses `<Mon> <d> at <h>[:mm]<am|pm> (<IANA zone>)`.
    private static func reset(from text: String, now: Date) -> UsageMeter.Reset {
        // Claude Code has written the date and the time separated both by ` at ` and by `, `.
        // Both are accepted, so a change of wording on that one separator does not cost the countdown.
        guard let match = text.wholeMatch(of: #/([A-Za-z]{3}) (\d{1,2}),?(?: at)? (\d{1,2})(?::(\d{2}))?(am|pm) \((.+)\)/#),
              let monthIndex = monthAbbreviations.firstIndex(of: match.1.lowercased()),
              let day = Int(match.2),
              let hour12 = Int(match.3), (1...12).contains(hour12),
              let zone = TimeZone(identifier: String(match.6))
        else { return .unparsed(text) }

        let minute = match.4.flatMap { Int($0) } ?? 0
        let hour = hour12 % 12 + (match.5 == "pm" ? 12 : 0)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        // The year is not printed, so take the one that lands closest to now.
        let currentYear = calendar.component(.year, from: now)
        let candidates = (currentYear - 1...currentYear + 1).compactMap { year in
            calendar.date(from: DateComponents(year: year, month: monthIndex + 1, day: day, hour: hour, minute: minute))
        }
        guard let closest = candidates.min(by: {
            abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now))
        }) else { return .unparsed(text) }
        return .at(closest)
    }
}
