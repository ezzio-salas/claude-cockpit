import Foundation

/// What recent Claude Code usage on this machine would have cost at API list prices.
/// On a subscription nothing is billed per token, so this is an equivalent, not a charge.
public struct ClaudeCost: Equatable, Sendable {
    /// US dollars since local midnight.
    public let today: Double
    /// US dollars over the last seven days.
    public let last7Days: Double
    /// Models used in the last seven days that have no known price. Their usage is missing from the totals.
    public let unpricedModels: [String]

    public init(today: Double, last7Days: Double, unpricedModels: [String]) {
        self.today = today
        self.last7Days = last7Days
        self.unpricedModels = unpricedModels
    }
}

public enum CostText {
    /// `~$3.40` below ten dollars and `~$140` above; a trailing `+` when part of the usage could not be priced.
    public static func text(_ dollars: Double, isPartial: Bool) -> String {
        let amount = dollars < 10 ? String(format: "%.2f", dollars) : String(format: "%.0f", dollars)
        return "~$\(amount)\(isPartial ? "+" : "")"
    }
}

/// Estimates `ClaudeCost` from the token counts in Claude Code's local transcripts.
public actor ClaudeCostEstimator {
    public static let defaultTranscripts = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    private struct ParsedTranscript {
        let modified: Date
        let size: Int
        let replies: [ReplyUsage]
    }

    private let transcripts: URL
    /// Transcripts already parsed, so that each refresh re-reads only the files that changed.
    private var parsed: [URL: ParsedTranscript] = [:]

    public init(transcripts: URL = ClaudeCostEstimator.defaultTranscripts) {
        self.transcripts = transcripts
    }

    /// Returns nil when the transcripts directory does not exist.
    public func estimate(now: Date, calendar: Calendar = .current) -> ClaudeCost? {
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        guard let recent = transcriptsModified(since: weekAgo) else { return nil }
        refreshParsedTranscripts(to: recent)

        let startOfToday = calendar.startOfDay(for: now)
        var today = 0.0
        var last7Days = 0.0
        var unpricedModels = Set<String>()
        for reply in distinctReplies() where reply.timestamp >= weekAgo {
            guard let rates = ModelPricing.rates(for: reply.model) else {
                unpricedModels.insert(reply.model)
                continue
            }
            let cost = Self.cost(of: reply, at: rates)
            last7Days += cost
            if reply.timestamp >= startOfToday {
                today += cost
            }
        }
        return ClaudeCost(today: today, last7Days: last7Days, unpricedModels: unpricedModels.sorted())
    }

    /// The transcripts that can hold a reply newer than `cutoff`, with their modification date and size.
    private func transcriptsModified(since cutoff: Date) -> [URL: (modified: Date, size: Int)]? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let root = transcripts.resolvingSymlinksInPath()
        // The enumerator is created even for a missing directory, so check for it first.
        guard FileManager.default.fileExists(atPath: root.path),
              let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys))
        else { return nil }

        var recent: [URL: (modified: Date, size: Int)] = [:]
        for case let file as URL in files where file.pathExtension == "jsonl" {
            guard let values = try? file.resourceValues(forKeys: keys),
                  let modified = values.contentModificationDate, modified >= cutoff,
                  let size = values.fileSize
            else { continue }
            recent[file] = (modified, size)
        }
        return recent
    }

    private func refreshParsedTranscripts(to recent: [URL: (modified: Date, size: Int)]) {
        parsed = parsed.filter { recent[$0.key] != nil }
        for (file, state) in recent {
            if let known = parsed[file], known.modified == state.modified, known.size == state.size {
                continue
            }
            guard let contents = try? Data(contentsOf: file) else { continue }
            parsed[file] = ParsedTranscript(
                modified: state.modified, size: state.size, replies: TranscriptParser.replies(in: contents)
            )
        }
    }

    /// One entry per reply. A reply is written once per content block, and again in every transcript that
    /// resumes its session; the line with the most output tokens is the finished one.
    private func distinctReplies() -> [ReplyUsage] {
        var byID: [String: ReplyUsage] = [:]
        for transcript in parsed.values {
            for reply in transcript.replies {
                if let seen = byID[reply.id], seen.outputTokens >= reply.outputTokens {
                    continue
                }
                byID[reply.id] = reply
            }
        }
        return Array(byID.values)
    }

    private static func cost(of reply: ReplyUsage, at rates: TokenRates) -> Double {
        let dollarsPerMillion = Double(reply.inputTokens) * rates.input
            + Double(reply.outputTokens) * rates.output
            + Double(reply.cacheReadTokens) * rates.cacheRead
            + Double(reply.cacheWrite5MinuteTokens) * rates.cacheWrite5Minutes
            + Double(reply.cacheWrite1HourTokens) * rates.cacheWrite1Hour
        return dollarsPerMillion / 1_000_000
    }
}
