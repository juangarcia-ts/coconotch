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

@Test func leavesSwitchedOffWidgetsOffHome() {
    let preferences = [
        WidgetPreference(id: "meetings", isEnabled: false),
        WidgetPreference(id: "timezones"),
    ]
    let ids = getHomeSummaryIDs(
        getEnabledWidgetIDs(preferences),
        summaryIDs: ["meetings", "timezones"],
        hiddenIDs: []
    )
    #expect(ids == ["timezones"])
}

@Test func formatsAppVersion() {
    #expect(formatAppVersion("0.1.0") == "CocoNotch 0.1.0")
    #expect(formatAppVersion("") == nil)
    #expect(formatAppVersion(nil) == nil)
}

@Test func leavesRoomForWidgetUnderTabsAndAboveFooter() {
    #expect(getWidgetMaxHeight(panelHeight: 300, tabBarHeight: 40, footerHeight: 26) == 234)
    #expect(getWidgetMaxHeight(panelHeight: 50, tabBarHeight: 40, footerHeight: 26) == 0)
}

@Test func widgetTopPaddingMakesRoomForShortcutHints() {
    #expect(getWidgetTopPadding(widgetShortcuts: .visible) == 20)
    #expect(getWidgetTopPadding(widgetShortcuts: .hidden) == 12)
    #expect(getWidgetTopPadding(widgetShortcuts: .disabled) == 12)
}

@Test func widgetShortcutDigitsFollowTheNumberRow() {
    #expect(getWidgetShortcutDigit(index: 0) == "1")
    #expect(getWidgetShortcutDigit(index: 8) == "9")
    #expect(getWidgetShortcutDigit(index: 9) == "0")
    #expect(getWidgetShortcutDigit(index: 10) == nil)
    #expect(getWidgetShortcutDigit(index: -1) == nil)
}
