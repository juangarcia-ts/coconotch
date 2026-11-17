import Foundation

public struct WidgetPreference: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var isEnabled: Bool

    public init(id: String, isEnabled: Bool = true) {
        self.id = id
        self.isEnabled = isEnabled
    }
}

/// Reads the saved widget order, keeping only widgets that still exist and adding new ones, enabled, right after the
/// widget they follow in the default order, so a widget meant to stay last (like Camera) does.
/// At least one widget always comes back enabled, even from hand-edited data, so the notch never opens empty.
public func decodeWidgetPreferences(_ stored: String, availableIDs: [String]) -> [WidgetPreference] {
    let saved = (try? JSONDecoder().decode([WidgetPreference].self, from: Data(stored.utf8))) ?? []
    let available = Set(availableIDs)
    var seenIDs: Set<String> = []
    let kept = saved.filter { available.contains($0.id) && seenIDs.insert($0.id).inserted }
    var preferences = kept
    for (index, id) in availableIDs.enumerated() where !seenIDs.contains(id) {
        let previousIndex = index == 0 ? nil : preferences.firstIndex { $0.id == availableIDs[index - 1] }
        preferences.insert(WidgetPreference(id: id), at: previousIndex.map { $0 + 1 } ?? 0)
    }
    if !preferences.isEmpty && !preferences.contains(where: \.isEnabled) {
        preferences[0].isEnabled = true
    }
    return preferences
}

/// The widget the notch opens to: the last one selected if it's still enabled, otherwise the first enabled one.
public func resolveSelectedWidgetID(_ selectedID: String, enabledIDs: [String]) -> String? {
    enabledIDs.contains(selectedID) ? selectedID : enabledIDs.first
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

/// The drop target past the last tab, where a dragged widget moves to the end.
public let widgetListEndID = "end"

/// Moves a dragged widget onto a target's spot: after it when dragged rightward, before it when dragged leftward,
/// like reordering a tab bar. Dropping on Home, which isn't in the list and always stays first, moves it to the front;
/// dropping on `widgetListEndID` moves it to the end.
public func moveWidget(_ id: String, onto targetID: String, in preferences: [WidgetPreference]) -> [WidgetPreference] {
    guard id != targetID, let from = preferences.firstIndex(where: { $0.id == id }) else { return preferences }
    let target =
        targetID == widgetListEndID ? preferences.count - 1 : preferences.firstIndex { $0.id == targetID } ?? 0
    var moved = preferences
    let widget = moved.remove(at: from)
    moved.insert(widget, at: target)
    return moved
}
