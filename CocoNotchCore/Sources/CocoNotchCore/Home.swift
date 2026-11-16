/// The widgets whose summaries Home shows, in the user's widget order: those that have one and weren't hidden.
public func getHomeSummaryIDs(_ orderedIDs: [String], summaryIDs: Set<String>, hiddenIDs: Set<String>) -> [String] {
    orderedIDs.filter { summaryIDs.contains($0) && !hiddenIDs.contains($0) }
}

/// Fewer cards than the chosen maximum share the row instead of leaving empty columns.
public func getHomeColumnCount(cardCount: Int, maxColumns: Int) -> Int {
    max(min(cardCount, maxColumns), 1)
}
