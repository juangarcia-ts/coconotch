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
    case 10_080: String(localized: "Weekly", bundle: .module)
    case let minutes where minutes % 1440 == 0: String(localized: "\(minutes / 1440)-day window", bundle: .module)
    case let minutes where minutes % 60 == 0: String(localized: "\(minutes / 60)-hour window", bundle: .module)
    default: String(localized: "\(minutes)-minute window", bundle: .module)
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
    return String(localized: "As of \(text)", bundle: .module)
}

/// The fullest shown limit across providers, for the heads-up and the Home card.
public func getFullestProviderLimit(
    _ candidates: [(provider: AIProvider, limit: UsageLimit)]
) -> (provider: AIProvider, limit: UsageLimit)? {
    candidates.max { $0.limit.percent < $1.limit.percent }
}

/// The limit the quiet closed-notch activity shows: the next to reset, such as the 5-hour session, or the fullest.
public func getIdleProviderLimit(
    _ candidates: [(provider: AIProvider, limit: UsageLimit)], showsFullest: Bool, now: Date
) -> (provider: AIProvider, limit: UsageLimit)? {
    if !showsFullest,
        let soonest = candidates.compactMap({ candidate in
            candidate.limit.resetsAt.flatMap { $0 > now ? (candidate, $0) : nil }
        })
        .min(by: { $0.1 < $1.1 })
    {
        return soonest.0
    }
    return getFullestProviderLimit(candidates)
}

/// Identifies a limit's heads-up. Each field is quoted on its own, so no two limits share a key.
public func makeUsageHeadsUpKey(provider: AIProvider, limit: UsageLimit) -> String {
    [provider.rawValue, limit.kind, limit.modelName].description
}

/// Each limit at or over the threshold, by heads-up key.
public func getDueUsageHeadsUps(
    _ candidates: [(provider: AIProvider, limit: UsageLimit)], threshold: Int
) -> [String: UsageLimit] {
    Dictionary(
        candidates.filter { $0.limit.percent >= threshold }
            .map { (makeUsageHeadsUpKey(provider: $0.provider, limit: $0.limit), $0.limit) },
        uniquingKeysWith: getMoreUrgentLimit)
}

/// Adds the limits dismissed now, keeping the more urgent reading where a limit was dismissed before.
public func mergeDismissedHeadsUps(
    _ dismissed: [String: UsageLimit], _ due: [String: UsageLimit]
) -> [String: UsageLimit] {
    dismissed.merging(due, uniquingKeysWith: getMoreUrgentLimit)
}

private func getMoreUrgentLimit(_ first: UsageLimit, _ second: UsageLimit) -> UsageLimit {
    getUsagePriority(second) > getUsagePriority(first) ? second : first
}

/// Keeps a dismissal while its limit stays over the threshold in the same window. Its reset ends it even when the next
/// window is already over the threshold by the time the numbers come in, say after the Mac slept through it.
public func pruneDismissedHeadsUps(
    _ dismissed: [String: UsageLimit], due: [String: UsageLimit], now: Date
) -> [String: UsageLimit] {
    dismissed.filter { key, limit in due[key] != nil && limit.resetsAt.map { $0 > now } ?? true }
}

/// Dismissed at this urgency or above, so running out still alerts once but dropping back from 100% doesn't.
public func isUsageHeadsUpDismissed(
    provider: AIProvider, limit: UsageLimit, dismissed: [String: UsageLimit]
) -> Bool {
    dismissed[makeUsageHeadsUpKey(provider: provider, limit: limit)].map {
        getUsagePriority($0) >= getUsagePriority(limit)
    } ?? false
}

/// The fullest limit not dismissed, so dismissing one doesn't hide another that climbs over the threshold later; the
/// fullest when all are.
public func getHeadsUpProviderLimit(
    _ candidates: [(provider: AIProvider, limit: UsageLimit)], dismissed: [String: UsageLimit]
) -> (provider: AIProvider, limit: UsageLimit)? {
    getFullestProviderLimit(
        candidates.filter { !isUsageHeadsUpDismissed(provider: $0.provider, limit: $0.limit, dismissed: dismissed) })
        ?? getFullestProviderLimit(candidates)
}
