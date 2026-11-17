import CocoNotchCore
import Testing

@Test func startsWithEveryWidgetEnabledInDefaultOrder() {
    #expect(
        decodeWidgetPreferences("", availableIDs: ["timezones", "meetings"]) == [
            WidgetPreference(id: "timezones"),
            WidgetPreference(id: "meetings"),
        ]
    )
}

@Test func keepsSavedOrderAndAddsNewWidgetsAfterTheirDefaultNeighbor() {
    let stored = encodeWidgetPreferences([
        WidgetPreference(id: "meetings", isEnabled: false),
        WidgetPreference(id: "removed"),
        WidgetPreference(id: "timezones"),
        WidgetPreference(id: "meetings"),
    ])
    #expect(
        decodeWidgetPreferences(stored, availableIDs: ["timezones", "meetings", "music"]) == [
            WidgetPreference(id: "meetings", isEnabled: false),
            WidgetPreference(id: "music"),
            WidgetPreference(id: "timezones"),
        ]
    )
}

@Test func addsNewWidgetsBeforeOneThatStaysLast() {
    let stored = encodeWidgetPreferences([WidgetPreference(id: "system"), WidgetPreference(id: "camera")])
    #expect(
        decodeWidgetPreferences(stored, availableIDs: ["new", "system", "clipboard", "camera"]).map(\.id) == [
            "new", "system", "clipboard", "camera",
        ]
    )
}

@Test func getsEnabledWidgetsInOrder() {
    let preferences = [
        WidgetPreference(id: "meetings"),
        WidgetPreference(id: "music", isEnabled: false),
        WidgetPreference(id: "timezones"),
    ]
    #expect(getEnabledWidgetIDs(preferences) == ["meetings", "timezones"])
}

@Test func keepsTheLastEnabledWidgetOn() {
    let preferences = [WidgetPreference(id: "meetings"), WidgetPreference(id: "timezones", isEnabled: false)]
    #expect(!canToggleWidget("meetings", in: preferences))
    #expect(canToggleWidget("timezones", in: preferences))
    #expect(canToggleWidget("meetings", in: [WidgetPreference(id: "meetings"), WidgetPreference(id: "timezones")]))
}

@Test func enablesFirstWidgetWhenStoredDataHasNoneOn() {
    let stored = encodeWidgetPreferences([
        WidgetPreference(id: "meetings", isEnabled: false),
        WidgetPreference(id: "timezones", isEnabled: false),
    ])
    #expect(
        decodeWidgetPreferences(stored, availableIDs: ["timezones", "meetings"]) == [
            WidgetPreference(id: "meetings"),
            WidgetPreference(id: "timezones", isEnabled: false),
        ]
    )
    #expect(decodeWidgetPreferences("", availableIDs: []).isEmpty)
}

@Test func resolvesSelectedWidget() {
    #expect(resolveSelectedWidgetID("meetings", enabledIDs: ["timezones", "meetings"]) == "meetings")
    #expect(resolveSelectedWidgetID("music", enabledIDs: ["timezones", "meetings"]) == "timezones")
    #expect(resolveSelectedWidgetID("", enabledIDs: ["meetings"]) == "meetings")
    #expect(resolveSelectedWidgetID("meetings", enabledIDs: []) == nil)
}

@Test func movesWidgetOntoTarget() {
    let preferences = ["a", "b", "c", "d"].map { WidgetPreference(id: $0) }
    func move(_ id: String, onto target: String) -> [String] {
        moveWidget(id, onto: target, in: preferences).map(\.id)
    }
    #expect(move("a", onto: "c") == ["b", "c", "a", "d"])
    #expect(move("d", onto: "b") == ["a", "d", "b", "c"])
    #expect(move("c", onto: homeWidgetID) == ["c", "a", "b", "d"])
    #expect(move("b", onto: "b") == ["a", "b", "c", "d"])
    #expect(move(homeWidgetID, onto: "c") == ["a", "b", "c", "d"])
    #expect(move("a", onto: widgetListEndID) == ["b", "c", "d", "a"])
    #expect(move("d", onto: widgetListEndID) == ["a", "b", "c", "d"])
}
