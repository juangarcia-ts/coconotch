import CocoNotchCore
import Foundation
import Testing

@Test func readsOnlyTheClaudeLoginFromCredentials() {
    let data = Data(
        """
        {"claudeAiOauth":{"accessToken":"token-1","refreshToken":"r","expiresAt":1800000000000},
        "mcpOAuth":{"other|1":{"accessToken":"not-this-one"}}}
        """.utf8)
    #expect(
        parseClaudeCredentials(data)
            == ClaudeCredentials(accessToken: "token-1", expiresAt: Date(timeIntervalSince1970: 1_800_000_000))
    )
    #expect(parseClaudeCredentials(Data("{\"mcpOAuth\":{}}".utf8)) == nil)
    #expect(parseClaudeCredentials(Data("{\"claudeAiOauth\":{\"accessToken\":\"\"}}".utf8)) == nil)
    #expect(parseClaudeCredentials(Data("not json".utf8)) == nil)
}

@Test func detectsExpiredToken() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(isClaudeTokenExpired(ClaudeCredentials(accessToken: "t", expiresAt: now - 1), now: now))
    #expect(!isClaudeTokenExpired(ClaudeCredentials(accessToken: "t", expiresAt: now + 60), now: now))
    #expect(!isClaudeTokenExpired(ClaudeCredentials(accessToken: "t", expiresAt: nil), now: now))
}

@Test func parsesUsageLimits() throws {
    let data = Data(
        """
        {"five_hour":{"utilization":74.0,"resets_at":"2026-11-16T23:00:00.527379+00:00"},
        "limits":[
          {"kind":"session","group":"session","percent":74,"resets_at":"2026-11-16T23:00:00.527379+00:00","scope":null},
          {"kind":"weekly_all","percent":24.4,"resets_at":"2026-11-22T18:00:00+00:00","scope":null},
          {"kind":"weekly_scoped","percent":0,"resets_at":null,"scope":{"model":{"id":null,"display_name":"Fable"}}}
        ]}
        """.utf8)
    let limits = try parseClaudeUsage(data)
    #expect(limits.map(\.kind) == ["session", "weekly_all", "weekly_scoped"])
    #expect(limits.map(\.percent) == [74, 24, 0])
    #expect(limits[0].resetsAt == parseUsageDate("2026-11-16T23:00:00+00:00"))
    #expect(limits[2].modelName == "Fable")
    #expect(limits[2].resetsAt == nil)
}

@Test func fallsBackToUsageWindows() throws {
    let data = Data(
        """
        {"five_hour":{"utilization":12.6,"resets_at":"2026-11-16T23:00:00+00:00"},
        "seven_day":{"utilization":3,"resets_at":null},"limits":[]}
        """.utf8)
    let limits = try parseClaudeUsage(data)
    #expect(
        limits == [
            UsageLimit(kind: "session", percent: 13, resetsAt: parseUsageDate("2026-11-16T23:00:00+00:00")),
            UsageLimit(kind: "weekly_all", percent: 3),
        ])
    #expect(throws: (any Error).self) { try parseClaudeUsage(Data("[]".utf8)) }
}

@Test func parsesUsageDates() {
    #expect(parseUsageDate("2026-11-16T23:00:00+00:00") == Date(timeIntervalSince1970: 1_794_870_000))
    #expect(parseUsageDate("2026-11-16T23:00:00.527379+00:00") == Date(timeIntervalSince1970: 1_794_870_000))
    #expect(parseUsageDate("soon") == nil)
}

@Test func titlesLimits() {
    #expect(formatLimitTitle(UsageLimit(kind: "session", percent: 0)) == "Current session")
    #expect(formatLimitTitle(UsageLimit(kind: "weekly_all", percent: 0)) == "Weekly · all models")
    #expect(formatLimitTitle(UsageLimit(kind: "weekly_scoped", percent: 0, modelName: "Fable")) == "Weekly · Fable")
    #expect(formatLimitTitle(UsageLimit(kind: "daily_extra", percent: 0)) == "Daily Extra")
}

@Test func formatsUsageAsUsedOrLeft() {
    #expect(formatUsagePercent(74, showsRemaining: false) == "74% used")
    #expect(formatUsagePercent(74, showsRemaining: true) == "26% left")
    #expect(formatUsagePercent(120, showsRemaining: true) == "0% left")
    #expect(getUsageBarFraction(74, showsRemaining: false) == 0.74)
    #expect(abs(getUsageBarFraction(74, showsRemaining: true) - 0.26) < 0.0001)
    #expect(getUsageBarFraction(150, showsRemaining: false) == 1)
}

@Test func formatsResetTime() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(formatResetTime(nil, now: now) == nil)
    #expect(formatResetTime(now - 5, now: now) == "Resetting now")
    #expect(formatResetTime(now + 8100, now: now)?.hasPrefix("Resets in 2") == true)
    let later = now + 3 * 86_400
    #expect(
        formatResetTime(later, now: now) == "Resets " + later.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    )
}

@Test func picksHeadsUpLimit() {
    let limits = [
        UsageLimit(kind: "session", percent: 85),
        UsageLimit(kind: "weekly_all", percent: 92),
        UsageLimit(kind: "weekly_scoped", percent: 10, modelName: "Fable"),
    ]
    #expect(getFullestLimit(limits, hiddenKinds: [])?.kind == "weekly_all")
    #expect(getUsageHeadsUpLimit(limits, hiddenKinds: [], threshold: 80)?.kind == "weekly_all")
    #expect(getUsageHeadsUpLimit(limits, hiddenKinds: ["weekly_all"], threshold: 80)?.kind == "session")
    #expect(getUsageHeadsUpLimit(limits, hiddenKinds: ["weekly_all"], threshold: 90) == nil)
    #expect(getUsagePriority(UsageLimit(kind: "session", percent: 100)) == .urgent)
    #expect(getUsagePriority(UsageLimit(kind: "session", percent: 99)) == .normal)
}

@Test func mapsUsageStatusCodes() {
    #expect(getClaudeUsageProblem(statusCode: 200) == nil)
    #expect(getClaudeUsageProblem(statusCode: 401) == .loginExpired)
    #expect(getClaudeUsageProblem(statusCode: 418) == .unexpectedResponse)
    for problem in [
        ClaudeUsageProblem.notConnected, .accessDeclined, .keychainLocked, .keychainError(9), .notSignedIn,
        .loginExpired, .network,
        .unexpectedResponse,
    ] {
        #expect(!getClaudeUsageProblemMessage(problem).isEmpty)
    }
}

@Test func filtersVisibleLimitsAndLevels() {
    let limits = [
        UsageLimit(kind: "session", percent: 10),
        UsageLimit(kind: "weekly_scoped", percent: 20, modelName: "A"),
        UsageLimit(kind: "weekly_scoped", percent: 30, modelName: "B"),
    ]
    #expect(getVisibleLimits(limits, hiddenKinds: ["weekly_scoped"]).map(\.kind) == ["session"])
    #expect(getVisibleLimits(limits, hiddenKinds: []).count == 3)
    #expect(getUsageLevel(74) == .comfortable)
    #expect(getUsageLevel(75) == .high)
    #expect(getUsageLevel(90) == .critical)
}

@Test func mapsSecurityToolExitCodes() {
    #expect(getCredentialsProblem(exitCode: 0) == nil)
    #expect(getCredentialsProblem(exitCode: 44) == .notSignedIn)
    #expect(getCredentialsProblem(exitCode: 51) == .accessDeclined)
    #expect(getCredentialsProblem(exitCode: 128) == .accessDeclined)
    #expect(getCredentialsProblem(exitCode: 36) == .keychainLocked)
    #expect(getCredentialsProblem(exitCode: 9) == .keychainError(9))
    #expect(getClaudeUsageProblemMessage(.keychainError(9)).contains("9"))
}

@Test func keepsNumbersThroughTransientProblems() {
    #expect(getClaudeUsageProblem(statusCode: 429) == .network)
    #expect(getClaudeUsageProblem(statusCode: 503) == .network)
    #expect(getClaudeUsageProblem(statusCode: 404) == .unexpectedResponse)
    #expect(isTransientUsageProblem(.network))
    #expect(isTransientUsageProblem(.keychainLocked))
    #expect(isTransientUsageProblem(.keychainError(9)))
    #expect(!isTransientUsageProblem(.accessDeclined))
    #expect(!isTransientUsageProblem(.loginExpired))
}
