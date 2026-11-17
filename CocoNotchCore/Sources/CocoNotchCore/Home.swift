/// The widgets whose summaries Home shows: enabled ones, in the user's order, that have a summary not hidden from
/// Home. A switched-off widget's card would open nothing, so `enabledIDs` holds only widgets that are on.
public func getHomeSummaryIDs(_ enabledIDs: [String], summaryIDs: Set<String>, hiddenIDs: Set<String>) -> [String] {
    enabledIDs.filter { summaryIDs.contains($0) && !hiddenIDs.contains($0) }
}

public let homeWidgetID = "home"

/// The notch's tabs: Home first when shown, then the enabled widgets in the user's order.
public func getTabIDs(enabledIDs: [String], showsHome: Bool) -> [String] {
    (showsHome ? [homeWidgetID] : []) + enabledIDs
}

/// Splits items into rows of `columnCount`, the last row holding whatever is left.
public func makeRows<Item>(_ items: [Item], columnCount: Int) -> [[Item]] {
    stride(from: 0, to: items.count, by: max(columnCount, 1)).map {
        Array(items[$0..<min($0 + max(columnCount, 1), items.count)])
    }
}

/// Fewer cards than the chosen maximum share the row instead of leaving empty columns.
public func getHomeColumnCount(cardCount: Int, maxColumns: Int) -> Int {
    max(min(cardCount, maxColumns), 1)
}

/// "CocoNotch 0.1.0" for the notch footer, or nil when the bundle has no version.
public func formatAppVersion(_ version: String?) -> String? {
    guard let version, !version.isEmpty else { return nil }
    return "CocoNotch \(version)"
}

/// The room left for a widget in the open panel once the tab bar and footer are placed.
public func getWidgetMaxHeight(panelHeight: Double, tabBarHeight: Double, footerHeight: Double) -> Double {
    max(panelHeight - tabBarHeight - footerHeight, 0)
}

public enum WidgetShortcutsMode: String, CaseIterable, Sendable {
    /// ⌘-number switches widgets and each widget icon shows its shortcut.
    case visible
    case hidden
    /// No shortcuts, so opening the notch leaves the keyboard with the app the user is in.
    case disabled
}

/// The space above the widget content, with extra room for the shortcut hints under the widget icons.
public func getWidgetTopPadding(widgetShortcuts: WidgetShortcutsMode) -> Double {
    widgetShortcuts == .visible ? 20 : 12
}

/// The keys that pick the widget at `index`: ⌘1–⌘9 then ⌘0, like the number row, then ⌥⌘1–⌥⌘0; nil after that.
public struct WidgetTabShortcut: Equatable, Sendable {
    public let digit: Character
    public let usesOption: Bool

    public var label: String { (usesOption ? "⌥⌘" : "⌘") + String(digit) }
}

public func getWidgetTabShortcut(index: Int) -> WidgetTabShortcut? {
    guard (0..<20).contains(index) else { return nil }
    let position = index % 10
    return WidgetTabShortcut(digit: position == 9 ? "0" : Character(String(position + 1)), usesOption: index >= 10)
}
