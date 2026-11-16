import Foundation

public enum AIProvider: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex

    public var id: String { rawValue }
}

public func getProviderName(_ provider: AIProvider) -> String {
    switch provider {
    case .claude: "Claude"
    case .codex: "Codex"
    }
}

/// The providers the user chose to see, in a fixed order.
public func getShownProviders(showsClaude: Bool, showsCodex: Bool) -> [AIProvider] {
    AIProvider.allCases.filter { $0 == .claude ? showsClaude : showsCodex }
}

/// The provider the tab opens to: the last one picked if it's still shown, otherwise the first shown one.
public func resolveProvider(_ stored: String, shown: [AIProvider]) -> AIProvider? {
    AIProvider(rawValue: stored).flatMap { shown.contains($0) ? $0 : nil } ?? shown.first
}

/// A Codex rate-limit snapshot, as recorded in its newest session log.
public struct CodexUsage: Equatable, Sendable {
    public let limits: [UsageLimit]
    public let recordedAt: Date?

    public init(limits: [UsageLimit], recordedAt: Date?) {
        self.limits = limits
        self.recordedAt = recordedAt
    }
}

private struct CodexEvent: Decodable {
    struct Payload: Decodable {
        let rateLimits: RateLimits?

        enum CodingKeys: String, CodingKey {
            case rateLimits = "rate_limits"
        }
    }

    struct RateLimits: Decodable {
        let primary: Window?
        let secondary: Window?
    }

    struct Window: Decodable {
        let usedPercent: Double
        let windowMinutes: Int?
        let resetsAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowMinutes = "window_minutes"
            case resetsAt = "resets_at"
        }
    }

    let timestamp: String?
    let payload: Payload?
}

/// The newest rate-limit snapshot in a Codex session log, one JSON event per line. The log also holds the
/// conversation; only lines carrying `rate_limits` are decoded.
public func parseCodexUsage(_ log: String) -> CodexUsage? {
    for line in log.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
        guard let event = try? JSONDecoder().decode(CodexEvent.self, from: Data(line.utf8)),
            let rateLimits = event.payload?.rateLimits
        else { continue }
        let windows: [(String, CodexEvent.Window?)] = [
            ("primary", rateLimits.primary), ("secondary", rateLimits.secondary),
        ]
        let limits = windows.compactMap { name, window in
            window.map {
                UsageLimit(
                    kind: "codex_\(name)",
                    percent: Int($0.usedPercent.rounded()),
                    resetsAt: $0.resetsAt.map { Date(timeIntervalSince1970: $0) },
                    windowMinutes: $0.windowMinutes
                )
            }
        }
        return CodexUsage(limits: limits, recordedAt: event.timestamp.flatMap(parseUsageDate))
    }
    return nil
}

/// "5-hour window", "Weekly" or "2-day window", from a window's length.
public func formatWindowTitle(minutes: Int) -> String {
    switch minutes {
    case 10_080: "Weekly"
    case let minutes where minutes % 1440 == 0: "\(minutes / 1440)-day window"
    case let minutes where minutes % 60 == 0: "\(minutes / 60)-hour window"
    default: "\(minutes)-minute window"
    }
}

/// A snapshot can outlive its windows: once a window has reset, its usage is back to zero.
public func resetExpiredLimits(_ limits: [UsageLimit], now: Date) -> [UsageLimit] {
    limits.map { limit in
        guard let resetsAt = limit.resetsAt, resetsAt <= now else { return limit }
        return UsageLimit(kind: limit.kind, percent: 0, modelName: limit.modelName, windowMinutes: limit.windowMinutes)
    }
}

/// "As of 15:20" for today, otherwise the date, so an old Codex snapshot is never mistaken for live numbers.
public func formatAsOf(_ date: Date?, now: Date, calendar: Calendar) -> String? {
    guard let date else { return nil }
    let text =
        calendar.isDate(date, inSameDayAs: now)
        ? date.formatted(date: .omitted, time: .shortened)
        : date.formatted(.dateTime.month(.abbreviated).day())
    return "As of \(text)"
}

/// The fullest shown limit across providers, for the heads-up and the Home card.
public func getFullestProviderLimit(
    _ candidates: [(provider: AIProvider, limit: UsageLimit)]
) -> (provider: AIProvider, limit: UsageLimit)? {
    candidates.max { $0.limit.percent < $1.limit.percent }
}
