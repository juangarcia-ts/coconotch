import Foundation

public struct WidgetPreference: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var isEnabled: Bool

    public init(id: String, isEnabled: Bool = true) {
        self.id = id
        self.isEnabled = isEnabled
    }
}

/// Reads the saved widget order, keeping only widgets that still exist and adding new ones, enabled, at the end.
public func decodeWidgetPreferences(_ stored: String, availableIDs: [String]) -> [WidgetPreference] {
    let saved = (try? JSONDecoder().decode([WidgetPreference].self, from: Data(stored.utf8))) ?? []
    let available = Set(availableIDs)
    var seenIDs: Set<String> = []
    let kept = saved.filter { available.contains($0.id) && seenIDs.insert($0.id).inserted }
    let added = availableIDs.filter { !seenIDs.contains($0) }.map { WidgetPreference(id: $0) }
    return kept + added
}

public func encodeWidgetPreferences(_ preferences: [WidgetPreference]) -> String {
    guard let data = try? JSONEncoder().encode(preferences) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
}

public func getEnabledWidgetIDs(_ preferences: [WidgetPreference]) -> [String] {
    preferences.filter(\.isEnabled).map(\.id)
}

/// The last enabled widget can't be switched off, or the notch would open to nothing.
public func canToggleWidget(_ id: String, in preferences: [WidgetPreference]) -> Bool {
    let enabledIDs = getEnabledWidgetIDs(preferences)
    return !(enabledIDs == [id])
}
