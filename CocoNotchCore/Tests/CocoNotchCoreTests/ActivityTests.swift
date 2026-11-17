import CocoNotchCore
import Foundation
import Testing

private let now = Date(timeIntervalSince1970: 10_000)

private func makeActivity(
    _ id: String,
    widget: String,
    priority: ActivityPriority = .normal,
    at offset: TimeInterval = 0
) -> ActivitySummary {
    ActivitySummary(id: id, widgetID: widget, priority: priority, sortDate: now + offset)
}

@Test func ranksHigherPriorityFirst() {
    let ranked = rankActivities(
        [
            makeActivity("music", widget: "music", priority: .background),
            makeActivity("meeting", widget: "meetings", priority: .urgent),
        ],
        enabledWidgetIDs: ["music", "meetings"]
    )
    #expect(ranked.map(\.id) == ["meeting", "music"])
}

@Test func breaksPriorityTiesByWidgetOrder() {
    let activities = [makeActivity("a", widget: "meetings"), makeActivity("b", widget: "timezones")]
    #expect(rankActivities(activities, enabledWidgetIDs: ["timezones", "meetings"]).map(\.id) == ["b", "a"])
    #expect(rankActivities(activities, enabledWidgetIDs: ["meetings", "timezones"]).map(\.id) == ["a", "b"])
}

@Test func ranksSoonestFirstWithinAWidget() {
    let ranked = rankActivities(
        [makeActivity("later", widget: "meetings", at: 600), makeActivity("sooner", widget: "meetings", at: 60)],
        enabledWidgetIDs: ["meetings"]
    )
    #expect(ranked.map(\.id) == ["sooner", "later"])
}

@Test func dropsActivitiesFromDisabledWidgets() {
    let ranked = rankActivities(
        [makeActivity("meeting", widget: "meetings", priority: .urgent), makeActivity("song", widget: "music")],
        enabledWidgetIDs: ["music"]
    )
    #expect(ranked.map(\.id) == ["song"])
    #expect(rankActivities([], enabledWidgetIDs: ["music"]).isEmpty)
}

@Test func ranksPreferredWidgetFirstEvenAgainstHigherPriority() {
    let activities = [
        makeActivity("meeting", widget: "meetings", priority: .urgent),
        makeActivity("song", widget: "music", priority: .background),
    ]
    let ranked = rankActivities(activities, enabledWidgetIDs: ["meetings", "music"], preferredWidgetID: "music")
    #expect(ranked.map(\.id) == ["song", "meeting"])
    let disabledPreferred = rankActivities(activities, enabledWidgetIDs: ["meetings"], preferredWidgetID: "music")
    #expect(disabledPreferred.map(\.id) == ["meeting"])
}

@Test func changesAlertKeyForNewMeetingOrPriority() {
    let start = Date(timeIntervalSince1970: 100_000)
    func key(_ priority: ActivityPriority, _ date: Date, isSticky: Bool = false) -> String {
        makeAlertKey(
            ActivitySummary(id: "meetings.headsUp", widgetID: "meetings", priority: priority, sortDate: date),
            isSticky: isSticky)
    }
    #expect(key(.normal, start) == key(.normal, start))
    #expect(key(.normal, start) != key(.urgent, start))
    #expect(key(.normal, start) != key(.normal, start + 1800))
    #expect(key(.urgent, start, isSticky: true) != key(.urgent, start))
}

@Test(arguments: [([70.0, 40.0], 70.0), ([40.0, 90.0], 90.0), ([300.0, 40.0], 140.0), ([], 0.0)])
func sizesIslandSides(idealWidths: [Double], expected: Double) {
    #expect(getIslandSideWidth(idealWidths.map { CGFloat($0) }, maxWidth: 140) == CGFloat(expected))
}

@Test func switchesTabOnHoverOnlyAboveLowPriority() {
    #expect(getHoverWidgetID(makeActivity("music", widget: "music", priority: .background)) == "music")
    #expect(getHoverWidgetID(makeActivity("next", widget: "meetings", priority: .low)) == nil)
    #expect(getHoverWidgetID(nil) == nil)
}

@Test func treatsLowPriorityActivitiesAsNotNoteworthy() {
    #expect(isActivityNoteworthy(makeActivity("music", widget: "music", priority: .background)))
    #expect(!isActivityNoteworthy(makeActivity("usage", widget: "aiUsage", priority: .low)))
}
