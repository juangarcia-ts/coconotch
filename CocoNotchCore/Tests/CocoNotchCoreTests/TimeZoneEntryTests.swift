import CocoNotchCore
import Testing

private let local = TimeZoneEntry(identifier: localTimeZoneEntryID)

@Test func roundTripsEntries() {
    let entries = [
        TimeZoneEntry(identifier: "Europe/London", label: "Office"),
        TimeZoneEntry(identifier: localTimeZoneEntryID, label: "Home"),
        TimeZoneEntry(identifier: "Asia/Tokyo", isVisible: false),
    ]
    #expect(decodeTimeZoneEntries(encodeTimeZoneEntries(entries)) == entries)
}

@Test func readsLegacyCommaList() {
    #expect(
        decodeTimeZoneEntries("Europe/London,Asia/Tokyo") == [
            local,
            TimeZoneEntry(identifier: "Europe/London"),
            TimeZoneEntry(identifier: "Asia/Tokyo"),
        ]
    )
}

@Test(arguments: ["Europe/London, Asia/Tokyo", "Europe/London,,Asia/Tokyo,", "Europe/London,Asia/Tokyo,Europe/London"])
func cleansLegacyList(stored: String) {
    #expect(decodeTimeZoneEntries(stored).map(\.identifier) == [localTimeZoneEntryID, "Europe/London", "Asia/Tokyo"])
}

@Test func dropsRepeatedAndBlankJSONEntries() {
    let entries = [
        TimeZoneEntry(identifier: "Asia/Tokyo", label: "First"),
        TimeZoneEntry(identifier: " "),
        TimeZoneEntry(identifier: "Asia/Tokyo", label: "Second"),
    ]
    #expect(decodeTimeZoneEntries(encodeTimeZoneEntries(entries)) == [local, entries[0]])
}

@Test(arguments: ["", "[", "{\"broken\": true}", "[{\"identifier\": 1}]"])
func fallsBackToLocalEntryOnUnreadableStorage(stored: String) {
    #expect(decodeTimeZoneEntries(stored) == [local])
}

@Test func getsVisibleEntries() {
    let entries = [
        TimeZoneEntry(identifier: "Asia/Tokyo"),
        TimeZoneEntry(identifier: localTimeZoneEntryID, isVisible: false),
        TimeZoneEntry(identifier: "Europe/London"),
    ]
    #expect(
        getVisibleEntries(entries, localIdentifier: "America/Sao_Paulo").map(\.identifier) == [
            "Asia/Tokyo", "Europe/London",
        ])
}

@Test func addsLocalEntryFirstOnlyWhenMissing() {
    #expect(decodeTimeZoneEntries("Asia/Tokyo").map(\.identifier) == [localTimeZoneEntryID, "Asia/Tokyo"])
    let moved = encodeTimeZoneEntries([
        TimeZoneEntry(identifier: "Asia/Tokyo"),
        TimeZoneEntry(identifier: localTimeZoneEntryID, label: "Home", isVisible: false),
    ])
    let decoded = decodeTimeZoneEntries(moved)
    #expect(decoded.map(\.identifier) == ["Asia/Tokyo", localTimeZoneEntryID])
    #expect(decoded.last?.label == "Home")
    #expect(decoded.last?.isVisible == false)
}

@Test func resolvesLocalEntryToCurrentZone() {
    #expect(
        resolveTimeZoneIdentifier(localTimeZoneEntryID, localIdentifier: "America/Sao_Paulo") == "America/Sao_Paulo")
    #expect(resolveTimeZoneIdentifier("Asia/Tokyo", localIdentifier: "America/Sao_Paulo") == "Asia/Tokyo")
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

@Test func formatsTimeZoneCaption() {
    #expect(
        formatTimeZoneCaption(identifier: "America/Sao_Paulo", abbreviation: "GMT-3", isLocal: true)
            == "America/Sao_Paulo · GMT-3 · Current time zone"
    )
    #expect(formatTimeZoneCaption(identifier: "Asia/Tokyo", abbreviation: nil, isLocal: false) == "Asia/Tokyo")
}

@Test func keepsPinnedCitiesInPlaceWhileTravelling() {
    let stored = encodeTimeZoneEntries([
        TimeZoneEntry(identifier: "America/Los_Angeles"),
        TimeZoneEntry(identifier: "Asia/Tokyo", label: "Office"),
    ])
    let entries = decodeTimeZoneEntries(stored)
    #expect(entries.map(\.identifier) == [localTimeZoneEntryID, "America/Los_Angeles", "Asia/Tokyo"])
    #expect(entries.last?.label == "Office")
    // Only the city matching the current zone hides; the pins themselves never move or change.
    #expect(
        getVisibleEntries(entries, localIdentifier: "America/Los_Angeles").map(\.identifier)
            == [localTimeZoneEntryID, "Asia/Tokyo"]
    )
    #expect(
        getVisibleEntries(entries, localIdentifier: "Asia/Tokyo").map(\.identifier)
            == [localTimeZoneEntryID, "America/Los_Angeles"]
    )
}

@Test func hidesCityThatIsTheCurrentZoneWhileLocalShows() {
    let entries = [local, TimeZoneEntry(identifier: "Asia/Tokyo"), TimeZoneEntry(identifier: "Europe/London")]
    #expect(
        getVisibleEntries(entries, localIdentifier: "Asia/Tokyo").map(\.identifier) == [
            localTimeZoneEntryID, "Europe/London",
        ])
    let localHidden = [
        TimeZoneEntry(identifier: localTimeZoneEntryID, isVisible: false), TimeZoneEntry(identifier: "Asia/Tokyo"),
    ]
    #expect(getVisibleEntries(localHidden, localIdentifier: "Asia/Tokyo").map(\.identifier) == ["Asia/Tokyo"])
}

@Test func countsLocalEntryAsAddedZone() {
    #expect(
        getAddedTimeZoneIdentifiers(
            [local, TimeZoneEntry(identifier: "Asia/Tokyo")], localIdentifier: "America/Sao_Paulo")
            == ["America/Sao_Paulo", "Asia/Tokyo"]
    )
}
