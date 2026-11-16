import CocoNotchCore
import Testing

@Test func roundTripsEntries() {
    let entries = [
        TimeZoneEntry(identifier: "Europe/London", label: "Office"),
        TimeZoneEntry(identifier: "Asia/Tokyo", isVisible: false),
    ]
    #expect(decodeTimeZoneEntries(encodeTimeZoneEntries(entries)) == entries)
}

@Test func readsLegacyCommaList() {
    #expect(
        decodeTimeZoneEntries("Europe/London,Asia/Tokyo") == [
            TimeZoneEntry(identifier: "Europe/London"),
            TimeZoneEntry(identifier: "Asia/Tokyo"),
        ]
    )
}

@Test(arguments: ["Europe/London, Asia/Tokyo", "Europe/London,,Asia/Tokyo,", "Europe/London,Asia/Tokyo,Europe/London"])
func cleansLegacyList(stored: String) {
    #expect(decodeTimeZoneEntries(stored).map(\.identifier) == ["Europe/London", "Asia/Tokyo"])
}

@Test func dropsRepeatedAndBlankJSONEntries() {
    let entries = [
        TimeZoneEntry(identifier: "Asia/Tokyo", label: "First"),
        TimeZoneEntry(identifier: " "),
        TimeZoneEntry(identifier: "Asia/Tokyo", label: "Second"),
    ]
    #expect(decodeTimeZoneEntries(encodeTimeZoneEntries(entries)) == [entries[0]])
}

@Test(arguments: ["", "[", "{\"broken\": true}", "[{\"identifier\": 1}]"])
func ignoresUnreadableStorage(stored: String) {
    #expect(decodeTimeZoneEntries(stored).isEmpty)
}

@Test func getsVisibleEntriesWithoutLocalZone() {
    let entries = [
        TimeZoneEntry(identifier: "America/Sao_Paulo"),
        TimeZoneEntry(identifier: "Europe/London", isVisible: false),
        TimeZoneEntry(identifier: "Asia/Tokyo"),
    ]
    #expect(
        getVisibleEntries(entries, localIdentifier: "America/Sao_Paulo").map(\.identifier) == ["Asia/Tokyo"]
    )
}

@Test func searchesByCityIgnoringCaseAndAccents() {
    let identifiers = ["America/Sao_Paulo", "America/New_York", "Europe/London", "Asia/Tokyo"]
    #expect(searchTimeZoneIdentifiers("são", in: identifiers, limit: 5) == ["America/Sao_Paulo"])
    #expect(searchTimeZoneIdentifiers("YORK", in: identifiers, limit: 5) == ["America/New_York"])
    #expect(searchTimeZoneIdentifiers("o", in: identifiers, limit: 2).count == 2)
    #expect(searchTimeZoneIdentifiers("  ", in: identifiers, limit: 5).isEmpty)
    #expect(searchTimeZoneIdentifiers("america", in: identifiers, limit: 5).isEmpty)
}

@Test func ranksCitiesStartingWithQueryFirst() {
    let identifiers = ["Asia/Nicosia", "Australia/Sydney", "Europe/Sofia"]
    #expect(
        searchTimeZoneIdentifiers("s", in: identifiers, limit: 5) == [
            "Australia/Sydney", "Europe/Sofia", "Asia/Nicosia",
        ])
}

@Test func excludesAlreadyAddedIdentifiers() {
    let identifiers = ["Europe/London", "America/Los_Angeles"]
    #expect(
        searchTimeZoneIdentifiers("lo", in: identifiers, excluding: ["Europe/London"], limit: 5) == [
            "America/Los_Angeles"
        ])
}

@Test(arguments: [("", nil), ("   ", nil), ("Mom", "Mom"), ("New ", "New ")] as [(String, String?)])
func normalizesLabel(text: String, expected: String?) {
    #expect(normalizeLabel(text) == expected)
}

@Test func buildsDisplayTitle() {
    #expect(getDisplayTitle(label: nil, identifier: "Asia/Tokyo", flag: "🇯🇵") == "🇯🇵 Tokyo")
    #expect(getDisplayTitle(label: "Office", identifier: "Asia/Tokyo", flag: nil) == "Office")
}
