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

@Test(arguments: ["", "[", "{\"broken\": true}", "[{\"identifier\": 1}]"])
func ignoresUnreadableStorage(stored: String) {
    #expect(decodeTimeZoneEntries(stored).isEmpty)
}

@Test func searchesByCityIgnoringCaseAndAccents() {
    let identifiers = ["America/Sao_Paulo", "America/New_York", "Europe/London", "Asia/Tokyo"]
    #expect(searchTimeZoneIdentifiers("são", in: identifiers, limit: 5) == ["America/Sao_Paulo"])
    #expect(searchTimeZoneIdentifiers("YORK", in: identifiers, limit: 5) == ["America/New_York"])
    #expect(searchTimeZoneIdentifiers("o", in: identifiers, limit: 2).count == 2)
    #expect(searchTimeZoneIdentifiers("  ", in: identifiers, limit: 5).isEmpty)
    #expect(searchTimeZoneIdentifiers("america", in: identifiers, limit: 5).isEmpty)
}
