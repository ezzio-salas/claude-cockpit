import Foundation

public enum CompactDuration {
    /// `2d 5h`, `3h 12m`, `12m`, or `<1m` for anything under a minute.
    public static func text(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval) / 60
        let days = totalMinutes / 1440
        let hours = totalMinutes % 1440 / 60
        let minutes = totalMinutes % 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }
}

public enum ResetCountdown {
    public static func text(until reset: Date, now: Date) -> String {
        let remaining = reset.timeIntervalSince(now)
        return remaining > 0 ? "resets in \(CompactDuration.text(remaining))" : "resets now"
    }
}
