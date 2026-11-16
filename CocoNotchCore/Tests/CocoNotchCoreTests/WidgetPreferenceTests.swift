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

@Test func keepsSavedOrderAndAddsNewWidgetsAtTheEnd() {
    let stored = encodeWidgetPreferences([
        WidgetPreference(id: "meetings", isEnabled: false),
        WidgetPreference(id: "removed"),
        WidgetPreference(id: "timezones"),
        WidgetPreference(id: "meetings"),
    ])
    #expect(
        decodeWidgetPreferences(stored, availableIDs: ["timezones", "meetings", "music"]) == [
            WidgetPreference(id: "meetings", isEnabled: false),
            WidgetPreference(id: "timezones"),
            WidgetPreference(id: "music"),
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
