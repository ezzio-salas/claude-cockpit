import Foundation

/// The tokens one Claude reply consumed, as recorded in a Claude Code transcript.
struct ReplyUsage: Equatable {
    /// Identifies the reply across lines and files: its message id and request id.
    let id: String
    let timestamp: Date
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWrite5MinuteTokens: Int
    let cacheWrite1HourTokens: Int
}

/// Reads token usage out of Claude Code's JSON Lines transcripts.
enum TranscriptParser {
    /// Placeholder model on replies Claude Code generates itself; they consume no tokens.
    private static let syntheticModel = "<synthetic>"
    private static let usageMarker = Data(#""usage""#.utf8)
    private static let newline = UInt8(ascii: "\n")

    /// Returns one entry per assistant line that carries usage. Claude Code writes a reply as one line per
    /// content block, so the same reply can appear several times; `ClaudeCostEstimator` merges them.
    static func replies(in transcript: Data) -> [ReplyUsage] {
        let timestamps = ISO8601DateFormatter()
        timestamps.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return transcript.split(separator: newline).compactMap { line in
            // Most lines are prompts and tool results; skip them without decoding.
            guard line.range(of: usageMarker) != nil,
                  let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  entry["type"] as? String == "assistant",
                  let message = entry["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let messageID = message["id"] as? String,
                  let model = message["model"] as? String, model != syntheticModel,
                  let timestamp = (entry["timestamp"] as? String).flatMap(timestamps.date(from:))
            else { return nil }

            func tokens(_ key: String, in counts: [String: Any] = usage) -> Int {
                (counts[key] as? NSNumber)?.intValue ?? 0
            }
            let cacheWrites = usage["cache_creation"] as? [String: Any]
            let cacheWrite1Hour = cacheWrites.map { tokens("ephemeral_1h_input_tokens", in: $0) } ?? 0

            return ReplyUsage(
                id: "\(messageID)|\(entry["requestId"] as? String ?? "")",
                timestamp: timestamp,
                model: model,
                inputTokens: tokens("input_tokens"),
                outputTokens: tokens("output_tokens"),
                cacheReadTokens: tokens("cache_read_input_tokens"),
                // Without a breakdown, every cache write is the default five-minute kind.
                cacheWrite5MinuteTokens: tokens("cache_creation_input_tokens") - cacheWrite1Hour,
                cacheWrite1HourTokens: cacheWrite1Hour
            )
        }
    }
}
