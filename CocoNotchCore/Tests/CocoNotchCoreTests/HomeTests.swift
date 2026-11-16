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

@Test func putsHomeFirstWhenShown() {
    #expect(
        getTabIDs(enabledIDs: ["meetings", "timezones"], showsHome: true) == [homeWidgetID, "meetings", "timezones"])
    #expect(getTabIDs(enabledIDs: ["meetings"], showsHome: false) == ["meetings"])
}

@Test func makesRows() {
    #expect(makeRows([1, 2, 3, 4, 5], columnCount: 2) == [[1, 2], [3, 4], [5]])
    #expect(makeRows([1, 2], columnCount: 3) == [[1, 2]])
    #expect(makeRows([Int](), columnCount: 3).isEmpty)
    #expect(makeRows([1, 2], columnCount: 0) == [[1], [2]])
}
