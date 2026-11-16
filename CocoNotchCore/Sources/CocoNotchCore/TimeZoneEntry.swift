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
public func decodeTimeZoneEntries(_ stored: String) -> [TimeZoneEntry] {
    if let entries = try? JSONDecoder().decode([TimeZoneEntry].self, from: Data(stored.utf8)) {
        return entries
    }
    let isLegacyList = !stored.isEmpty && !stored.contains("[") && !stored.contains("{")
    return isLegacyList ? stored.split(separator: ",").map { TimeZoneEntry(identifier: String($0)) } : []
}

public func encodeTimeZoneEntries(_ entries: [TimeZoneEntry]) -> String {
    guard let data = try? JSONEncoder().encode(entries) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
}

/// Matches identifiers whose city name contains the query, ignoring case and accents.
public func searchTimeZoneIdentifiers(_ query: String, in identifiers: [String], limit: Int) -> [String] {
    let query = query.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return [] }
    let matches = identifiers.filter {
        getCityName(forTimeZoneIdentifier: $0).range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
            != nil
    }
    return Array(matches.prefix(limit))
}
