import CocoNotchCore
import Testing

@Test func parsesStoredIdentifiers() {
    #expect(parseTimeZoneIdentifiers("Europe/London,Asia/Tokyo") == ["Europe/London", "Asia/Tokyo"])
    #expect(parseTimeZoneIdentifiers("").isEmpty)
}

@Test(arguments: [
    ("America/Los_Angeles", "Los Angeles"),
    ("America/Argentina/Buenos_Aires", "Buenos Aires"),
    ("UTC", "UTC"),
])
func getsCityName(identifier: String, expected: String) {
    #expect(getCityName(forTimeZoneIdentifier: identifier) == expected)
}

@Test func formatsOffsetWithSign() {
    #expect(formatOffset(seconds: 3 * 3600).hasPrefix("+"))
    #expect(formatOffset(seconds: -5 * 3600).hasPrefix("−"))
    #expect(formatOffset(seconds: 5 * 3600 + 30 * 60).contains("30"))
}
