import CocoNotchCore
import Testing

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

@Test func labelsLocalZoneAsHere() {
    #expect(formatOffsetLabel(seconds: 0, isLocal: true) == "Here")
    #expect(formatOffsetLabel(seconds: -18_000, isLocal: false) == formatOffset(seconds: -18_000))
}
