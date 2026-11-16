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
