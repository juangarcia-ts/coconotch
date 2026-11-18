import Foundation

/// The entry for the Mac's own time zone, which follows the Mac when the user travels.
public let localTimeZoneEntryID = "local"

public struct TimeZoneEntry: Codable, Equatable, Identifiable, Sendable {
    public var identifier: String
    public var label: String?
    public var isVisible: Bool

    public var id: String { identifier }

    public init(identifier: String, label: String? = nil, isVisible: Bool = true) {
        self.identifier = identifier
        self.label = label
        self.isVisible = isVisible
    }
}

/// Reads the stored JSON list, or the comma-separated identifiers that versions before 0.2 stored.
/// Blank and repeated identifiers are dropped, because the identifier is each entry's `id` in SwiftUI lists.
/// The local entry is added first when missing, where the local time used to always show; it can be hidden, not
/// removed. Stored cities are never turned into it: they are pins, and `getVisibleEntries` hides a duplicate.
public func decodeTimeZoneEntries(_ stored: String) -> [TimeZoneEntry] {
    let entries: [TimeZoneEntry]
    if let decoded = try? JSONDecoder().decode([TimeZoneEntry].self, from: Data(stored.utf8)) {
        entries = decoded
    } else if !stored.contains("[") && !stored.contains("{") {
        entries = stored.split(separator: ",").map { TimeZoneEntry(identifier: String($0)) }
    } else {
        entries = []
    }

    var seenIdentifiers: Set<String> = []
    let unique: [TimeZoneEntry] = entries.compactMap { entry in
        var entry = entry
        entry.identifier = entry.identifier.trimmingCharacters(in: .whitespaces)
        guard !entry.identifier.isEmpty, seenIdentifiers.insert(entry.identifier).inserted else { return nil }
        return entry
    }
    return seenIdentifiers.contains(localTimeZoneEntryID)
        ? unique : [TimeZoneEntry(identifier: localTimeZoneEntryID)] + unique
}

public func encodeTimeZoneEntries(_ entries: [TimeZoneEntry]) -> String {
    guard let data = try? JSONEncoder().encode(entries) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
}

/// The shown entries. A city that is also the current zone, say Tokyo while in Tokyo, is left out while the local
/// entry is shown, so the same clock never appears twice.
public func getVisibleEntries(_ entries: [TimeZoneEntry], localIdentifier: String) -> [TimeZoneEntry] {
    let showsLocal = entries.contains { $0.identifier == localTimeZoneEntryID && $0.isVisible }
    return entries.filter { $0.isVisible && !(showsLocal && $0.identifier == localIdentifier) }
}

/// More cities than this don't fit Home's card beside the music panel.
public let maxHomeTimeZoneCount = 2

/// The cities Home's card shows. The current zone is left out, since its time is already on the menu bar clock.
public func getHomeEntries(_ entries: [TimeZoneEntry], localIdentifier: String, count: Int) -> [TimeZoneEntry] {
    let others = entries.filter {
        $0.isVisible && resolveTimeZoneIdentifier($0.identifier, localIdentifier: localIdentifier) != localIdentifier
    }
    return Array(others.prefix(clampHomeTimeZoneCount(count)))
}

/// Brings a saved count into 1...max, since older versions allowed up to four.
public func clampHomeTimeZoneCount(_ count: Int) -> Int {
    min(max(count, 1), maxHomeTimeZoneCount)
}

/// Zones the add search shouldn't offer: those in the list, the local entry counted as the current zone.
public func getAddedTimeZoneIdentifiers(_ entries: [TimeZoneEntry], localIdentifier: String) -> Set<String> {
    Set(entries.map { resolveTimeZoneIdentifier($0.identifier, localIdentifier: localIdentifier) })
}

/// The real time zone identifier for an entry: the Mac's current one for the local entry.
public func resolveTimeZoneIdentifier(_ identifier: String, localIdentifier: String) -> String {
    identifier == localTimeZoneEntryID ? localIdentifier : identifier
}

/// Matches identifiers whose city name contains the query, ignoring case and accents.
/// Cities that start with the query come first, so pressing Return adds the most likely one.
public func searchTimeZoneIdentifiers(
    _ query: String,
    in identifiers: [String],
    excluding excludedIdentifiers: Set<String> = [],
    limit: Int
) -> [String] {
    let query = query.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return [] }
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    var prefixMatches: [String] = []
    var otherMatches: [String] = []
    for identifier in identifiers where !excludedIdentifiers.contains(identifier) {
        let city = getCityName(forTimeZoneIdentifier: identifier)
        if city.range(of: query, options: options.union(.anchored)) != nil {
            prefixMatches.append(identifier)
        } else if city.range(of: query, options: options) != nil {
            otherMatches.append(identifier)
        }
    }
    return Array((prefixMatches + otherMatches).prefix(limit))
}

/// Keeps what the user typed, but treats a blank label as no label so the city name shows instead.
public func normalizeLabel(_ text: String) -> String? {
    text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text
}

public func getDisplayTitle(label: String?, identifier: String) -> String {
    label ?? getCityName(forTimeZoneIdentifier: identifier)
}

/// The line under an entry's alias field, such as "America/Los_Angeles · GMT-8 · Current time zone".
public func formatTimeZoneCaption(identifier: String, abbreviation: String?, isLocal: Bool) -> String {
    [identifier, abbreviation, isLocal ? String(localized: "Current time zone", bundle: .module) : nil].compactMap {
        $0
    }.joined(separator: " · ")
}
