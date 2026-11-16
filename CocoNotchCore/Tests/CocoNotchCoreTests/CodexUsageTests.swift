import CocoNotchCore
import Foundation
import Testing

private let sampleLog = """
    {"timestamp":"2026-10-14T19:50:00.000Z","type":"response_item","payload":{"type":"message","content":"hi"}}
    {"timestamp":"2026-10-14T19:51:05.917Z","type":"event_msg","payload":{"type":"token_count","info":{},\
    "rate_limits":{"limit_id":"codex","primary":{"used_percent":29.0,"window_minutes":10080,"resets_at":1792511103},\
    "secondary":{"used_percent":61.4,"window_minutes":300,"resets_at":1792000000},"plan_type":"plus"}}}
    {"timestamp":"2026-10-14T19:52:00.000Z","type":"event_msg","payload":{"type":"agent_message","message":"done"}}
    """

@Test func parsesNewestCodexSnapshot() throws {
    let usage = try #require(parseCodexUsage(sampleLog))
    #expect(usage.limits.map(\.kind) == ["codex_primary", "codex_secondary"])
    #expect(usage.limits.map(\.percent) == [29, 61])
    #expect(usage.limits.map(\.windowMinutes) == [10_080, 300])
    #expect(usage.limits.first?.resetsAt == Date(timeIntervalSince1970: 1_792_511_103))
    #expect(usage.recordedAt == parseUsageDate("2026-10-14T19:51:05Z"))
    #expect(parseCodexUsage("{\"type\":\"message\"}") == nil)
    #expect(parseCodexUsage("") == nil)
}

@Test func titlesWindowsByLength() {
    #expect(formatWindowTitle(minutes: 10_080) == "Weekly")
    #expect(formatWindowTitle(minutes: 300) == "5-hour window")
    #expect(formatWindowTitle(minutes: 2880) == "2-day window")
    #expect(formatWindowTitle(minutes: 45) == "45-minute window")
    #expect(formatLimitTitle(UsageLimit(kind: "codex_secondary", percent: 0, windowMinutes: 300)) == "5-hour window")
}

@Test func zeroesWindowsThatHaveReset() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let limits = [
        UsageLimit(kind: "a", percent: 80, resetsAt: now - 1, windowMinutes: 300),
        UsageLimit(kind: "b", percent: 40, resetsAt: now + 60),
    ]
    let current = resetExpiredLimits(limits, now: now)
    #expect(current.map(\.percent) == [0, 40])
    #expect(current.first?.resetsAt == nil)
    #expect(current.first?.windowMinutes == 300)
}

@Test func choosesShownProviders() {
    #expect(getShownProviders(showsClaude: true, showsCodex: true) == [.claude, .codex])
    #expect(getShownProviders(showsClaude: false, showsCodex: true) == [.codex])
    #expect(resolveProvider("codex", shown: [.claude, .codex]) == .codex)
    #expect(resolveProvider("codex", shown: [.claude]) == .claude)
    #expect(resolveProvider("", shown: []) == nil)
    #expect(getProviderName(.codex) == "Codex")
}

@Test func formatsAsOf() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(formatAsOf(nil, now: now, calendar: calendar) == nil)
    #expect(
        formatAsOf(now - 60, now: now, calendar: calendar) == "As of "
            + (now - 60).formatted(date: .omitted, time: .shortened))
    let old = now - 30 * 86_400
    #expect(
        formatAsOf(old, now: now, calendar: calendar) == "As of " + old.formatted(.dateTime.month(.abbreviated).day()))
}

@Test func picksFullestLimitAcrossProviders() {
    let pick = getFullestProviderLimit([
        (.claude, UsageLimit(kind: "session", percent: 70)),
        (.codex, UsageLimit(kind: "codex_primary", percent: 88)),
    ])
    #expect(pick?.provider == .codex)
    #expect(getFullestProviderLimit([]) == nil)
}

@Test func keysHeadsUpByLimitResetAndUrgency() {
    let resetsAt = Date(timeIntervalSince1970: 1_800_000_000)
    let near = UsageLimit(kind: "session", percent: 85, resetsAt: resetsAt)
    let nearer = UsageLimit(kind: "session", percent: 92, resetsAt: resetsAt)
    let full = UsageLimit(kind: "session", percent: 100, resetsAt: resetsAt)
    let nextWindow = UsageLimit(kind: "session", percent: 85, resetsAt: resetsAt + 18_000)
    let key = makeUsageHeadsUpKey(provider: .claude, limit: near)
    // Creeping up doesn't bring a dismissed heads-up back; running out, a new window or another provider does.
    #expect(makeUsageHeadsUpKey(provider: .claude, limit: nearer) == key)
    #expect(makeUsageHeadsUpKey(provider: .claude, limit: full) != key)
    #expect(makeUsageHeadsUpKey(provider: .claude, limit: nextWindow) != key)
    #expect(makeUsageHeadsUpKey(provider: .codex, limit: near) != key)
    let jittered = UsageLimit(kind: "session", percent: 85, resetsAt: resetsAt - 0.1)
    #expect(makeUsageHeadsUpKey(provider: .claude, limit: jittered) == key)
}
