import Foundation

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
    return entries.compactMap { entry in
        var entry = entry
        entry.identifier = entry.identifier.trimmingCharacters(in: .whitespaces)
        guard !entry.identifier.isEmpty, seenIdentifiers.insert(entry.identifier).inserted else { return nil }
        return entry
    }
}

public func encodeTimeZoneEntries(_ entries: [TimeZoneEntry]) -> String {
    guard let data = try? JSONEncoder().encode(entries) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
}

/// The entries the notch shows next to the local time, which is always drawn on its own.
public func getVisibleEntries(_ entries: [TimeZoneEntry], localIdentifier: String) -> [TimeZoneEntry] {
    entries.filter { $0.isVisible && $0.identifier != localIdentifier }
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

public func getDisplayTitle(label: String?, identifier: String, flag: String?) -> String {
    let name = label ?? getCityName(forTimeZoneIdentifier: identifier)
    return flag.map { "\($0) \(name)" } ?? name
}
