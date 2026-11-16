import CocoNotchCore
import Testing

@Test func getsHomeSummaryIDsInWidgetOrder() {
    let ids = getHomeSummaryIDs(
        ["home", "meetings", "weather", "timezones"],
        summaryIDs: ["timezones", "meetings", "weather"],
        hiddenIDs: ["weather"]
    )
    #expect(ids == ["meetings", "timezones"])
}

@Test(arguments: [(0, 3, 1), (1, 3, 1), (2, 3, 2), (5, 3, 3), (5, 1, 1)])
func countsHomeColumns(cardCount: Int, maxColumns: Int, expected: Int) {
    #expect(getHomeColumnCount(cardCount: cardCount, maxColumns: maxColumns) == expected)
}
