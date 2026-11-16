import Foundation

/// The Keychain item Claude Code keeps its login in.
public let claudeCredentialsService = "Claude Code-credentials"

/// The endpoint Claude Code's own usage screen reads. It isn't documented, so its shape can change.
public let claudeUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")

public struct ClaudeCredentials: Equatable, Sendable {
    public let accessToken: String
    public let expiresAt: Date?

    public init(accessToken: String, expiresAt: Date?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }
}

private struct CredentialsFile: Decodable {
    struct OAuth: Decodable {
        let accessToken: String
        let expiresAt: Double?
    }

    let claudeAiOauth: OAuth?
}

/// Reads only the Claude login from the Keychain item, which also holds tokens for other services that are ignored.
public func parseClaudeCredentials(_ data: Data) -> ClaudeCredentials? {
    guard let oauth = (try? JSONDecoder().decode(CredentialsFile.self, from: data))?.claudeAiOauth,
        !oauth.accessToken.isEmpty
    else { return nil }
    return ClaudeCredentials(
        accessToken: oauth.accessToken,
        // Claude Code stores milliseconds since 1970.
        expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
    )
}

/// An expired token is never refreshed here: refreshing replaces the refresh token and would log Claude Code out.
public func isClaudeTokenExpired(_ credentials: ClaudeCredentials, now: Date) -> Bool {
    credentials.expiresAt.map { $0 <= now } ?? false
}

public struct UsageLimit: Equatable, Identifiable, Sendable {
    /// "session", "weekly_all" or "weekly_scoped" today; unknown kinds are kept and named from the raw value.
    public let kind: String
    public let percent: Int
    public let resetsAt: Date?
    public let modelName: String?

    public var id: String { kind + (modelName ?? "") }

    public init(kind: String, percent: Int, resetsAt: Date? = nil, modelName: String? = nil) {
        self.kind = kind
        self.percent = percent
        self.resetsAt = resetsAt
        self.modelName = modelName
    }
}

private struct UsageResponse: Decodable {
    struct Limit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable {
                let displayName: String?

                enum CodingKeys: String, CodingKey {
                    case displayName = "display_name"
                }
            }

            let model: Model?
        }

        let kind: String
        let percent: Double
        let resetsAt: String?
        let scope: Scope?

        enum CodingKeys: String, CodingKey {
            case kind, percent, scope
            case resetsAt = "resets_at"
        }
    }

    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    let limits: [Limit]?
    let fiveHour: Window?
    let sevenDay: Window?

    enum CodingKeys: String, CodingKey {
        case limits
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

/// Reads the usage response. The `limits` list is preferred, since it names per-model limits; older responses
/// only have the 5-hour and weekly windows.
public func parseClaudeUsage(_ data: Data) throws -> [UsageLimit] {
    let response = try JSONDecoder().decode(UsageResponse.self, from: data)
    if let limits = response.limits, !limits.isEmpty {
        return limits.map {
            UsageLimit(
                kind: $0.kind,
                percent: Int($0.percent.rounded()),
                resetsAt: $0.resetsAt.flatMap(parseUsageDate),
                modelName: $0.scope?.model?.displayName
            )
        }
    }
    let windows: [(String, UsageResponse.Window?)] = [
        ("session", response.fiveHour), ("weekly_all", response.sevenDay),
    ]
    return windows.compactMap { kind, window in
        guard let utilization = window?.utilization else { return nil }
        return UsageLimit(
            kind: kind,
            percent: Int(utilization.rounded()),
            resetsAt: window?.resetsAt.flatMap(parseUsageDate)
        )
    }
}

/// Parses "2026-11-16T23:00:00.527379+00:00". Foundation's ISO 8601 parsing stops at three fraction digits, so the
/// fraction, which only matters to the microsecond, is dropped first.
public func parseUsageDate(_ text: String) -> Date? {
    let trimmed = text.replacing(/\.\d+/, with: "")
    return try? Date(trimmed, strategy: .iso8601)
}

/// "Current session", "Weekly · all models" or "Weekly · Fable".
public func formatLimitTitle(_ limit: UsageLimit) -> String {
    switch limit.kind {
    case "session": "Current session"
    case "weekly_all": "Weekly · all models"
    case "weekly_scoped": "Weekly · \(limit.modelName ?? "one model")"
    default: limit.kind.replacing("_", with: " ").capitalized
    }
}

/// "74% used" or "26% left", as the user prefers.
public func formatUsagePercent(_ percent: Int, showsRemaining: Bool) -> String {
    showsRemaining ? "\(max(100 - percent, 0))% left" : "\(percent)% used"
}

/// How full a bar is drawn, from 0 to 1, matching the label: remaining usage empties as it is used up.
public func getUsageBarFraction(_ percent: Int, showsRemaining: Bool) -> Double {
    let used = min(max(Double(percent) / 100, 0), 1)
    return showsRemaining ? 1 - used : used
}

/// "Resets in 2h 15m" within a day, otherwise the weekday and time, such as "Resets Sat 15:00".
public func formatResetTime(_ resetsAt: Date?, now: Date) -> String? {
    guard let resetsAt else { return nil }
    let seconds = resetsAt.timeIntervalSince(now)
    guard seconds > 0 else { return "Resetting now" }
    if seconds < 24 * 3600 {
        let minutes = Int((seconds / 60).rounded(.up))
        return "Resets in "
            + Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }
    return "Resets " + resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
}

/// The fullest shown limit, for the Home card and the heads-up.
public func getFullestLimit(_ limits: [UsageLimit], hiddenKinds: Set<String>) -> UsageLimit? {
    getVisibleLimits(limits, hiddenKinds: hiddenKinds).max { $0.percent < $1.percent }
}

/// The limits the user chose to see. Per-model weekly limits share one kind, so one switch hides them all.
public func getVisibleLimits(_ limits: [UsageLimit], hiddenKinds: Set<String>) -> [UsageLimit] {
    limits.filter { !hiddenKinds.contains($0.kind) }
}

public enum UsageLevel: Sendable {
    case comfortable
    case high
    case critical
}

/// How worrying a limit looks, for its bar's colour.
public func getUsageLevel(_ percent: Int) -> UsageLevel {
    switch percent {
    case ..<75: .comfortable
    case ..<90: .high
    default: .critical
    }
}

/// The limit worth a heads-up in the closed notch: the fullest shown one, once it reaches `threshold` percent.
public func getUsageHeadsUpLimit(_ limits: [UsageLimit], hiddenKinds: Set<String>, threshold: Int) -> UsageLimit? {
    getFullestLimit(limits, hiddenKinds: hiddenKinds).flatMap { $0.percent >= threshold ? $0 : nil }
}

/// A limit that is used up is urgent; one getting close is only worth a normal heads-up.
public func getUsagePriority(_ limit: UsageLimit) -> ActivityPriority {
    limit.percent >= 100 ? .urgent : .normal
}

/// Why there are no usage numbers to show.
public enum ClaudeUsageProblem: Equatable, Sendable {
    case notConnected
    case accessDeclined
    /// macOS refused the Keychain read for another reason; the status is shown so it can be looked up.
    case keychainError(Int32)
    case notSignedIn
    case loginExpired
    case network
    case unexpectedResponse
}

public func getClaudeUsageProblemMessage(_ problem: ClaudeUsageProblem) -> String {
    switch problem {
    case .notConnected:
        "See your Claude Code limits here. CocoNotch reads your Claude Code login from the Keychain; macOS asks first."
    case .accessDeclined:
        "Keychain access was declined. Connect again and choose Always Allow so CocoNotch can read your usage."
    case .keychainError(let status):
        "macOS wouldn't share Claude Code's login with CocoNotch (Keychain error \(status)). Try connecting again."
    case .notSignedIn: "Claude Code isn't signed in on this Mac. Run `claude` and sign in, then try again."
    case .loginExpired: "Your Claude Code login has expired. Open Claude Code once to refresh it, then try again."
    case .network: "Usage couldn't be loaded. Check your connection and try again."
    case .unexpectedResponse: "Claude's usage service answered in an unexpected way. It may have changed."
    }
}

/// What an HTTP status from the usage endpoint means for the widget; nil means the body can be read.
public func getClaudeUsageProblem(statusCode: Int) -> ClaudeUsageProblem? {
    switch statusCode {
    case 200..<300: nil
    case 401, 403: .loginExpired
    default: .unexpectedResponse
    }
}

/// What a Keychain read status means for the widget; nil means the login was read.
/// -25300 is errSecItemNotFound, -128 errSecUserCanceled and -25293 errSecAuthFailed.
public func getCredentialsProblem(status: Int32) -> ClaudeUsageProblem? {
    switch status {
    case 0: nil
    case -25300: .notSignedIn
    case -128, -25293: .accessDeclined
    default: .keychainError(status)
    }
}
