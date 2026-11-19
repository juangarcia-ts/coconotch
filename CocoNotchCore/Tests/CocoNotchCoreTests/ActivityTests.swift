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

@Test func widensIslandSidesPastTheCapForTheirMinimum() {
    #expect(getIslandSideWidth([300, 40], minWidths: [150, 20], maxWidth: 140) == 150)
    #expect(getIslandSideWidth([300, 40], minWidths: [60, 20], maxWidth: 140) == 140)
}

@Test func switchesTabOnHoverOnlyAboveLowPriority() {
    #expect(getHoverWidgetID(makeActivity("music", widget: "music", priority: .background)) == "music")
    #expect(getHoverWidgetID(makeActivity("next", widget: "meetings", priority: .low)) == nil)
    #expect(getHoverWidgetID(nil) == nil)
}

@Test func countsOnlyNoteworthyActivitiesOnNeitherSide() {
    let activities = [
        makeActivity("heads-up", widget: "meetings", priority: .urgent),
        makeActivity("other-meeting", widget: "meetings", priority: .normal),
        makeActivity("music", widget: "music", priority: .background),
        makeActivity("usage", widget: "aiUsage", priority: .low),
    ]
    #expect(countHiddenActivities(activities, shownIDs: ["heads-up", "music"]) == 1)
    #expect(countHiddenActivities(activities, shownIDs: ["music", "heads-up"]) == 1)
    #expect(countHiddenActivities(activities, shownIDs: ["heads-up", nil]) == 2)
    #expect(countHiddenActivities(activities, shownIDs: ["heads-up", "other-meeting", "music"]) == 0)
}

@Test func marksTheShownWidgetHoverDoesNotOpen() {
    let heads = makeActivity("heads-up", widget: "meetings", priority: .normal)
    let usage = makeActivity("usage", widget: "aiUsage", priority: .low)
    let ranked = [heads, usage]
    // Hovering opens Meetings, so quiet AI Usage gets the dot on either side.
    #expect(getMarkedWidgetIDs(ranked, sides: [heads, usage]) == ["meetings", "aiUsage"])
    #expect(getMarkedWidgetIDs(ranked, sides: [usage, heads]) == ["meetings", "aiUsage"])
    // Alone, a quiet activity stays unmarked.
    #expect(getMarkedWidgetIDs([usage], sides: [usage, nil]).isEmpty)
}

@Test func treatsLowPriorityActivitiesAsNotNoteworthy() {
    #expect(isActivityNoteworthy(makeActivity("music", widget: "music", priority: .background)))
    #expect(!isActivityNoteworthy(makeActivity("usage", widget: "aiUsage", priority: .low)))
}

@Test func pairsTheWinnerWithTheNextActivityFromAnotherWidget() {
    let ranked = [
        makeActivity("heads-up", widget: "meetings", priority: .urgent),
        makeActivity("next", widget: "meetings", priority: .low),
        makeActivity("usage", widget: "aiUsage", priority: .low),
    ]
    let sides = pickIslandSides(ranked, isSplit: true, rightWidgetID: nil)
    #expect(sides.left?.id == "heads-up")
    #expect(sides.right?.id == "usage")
    #expect(pickIslandSides(Array(ranked.prefix(2)), isSplit: true, rightWidgetID: nil).right == nil)
    #expect(pickIslandSides(ranked, isSplit: false, rightWidgetID: nil).right == nil)
    #expect(pickIslandSides([], isSplit: true, rightWidgetID: nil).left == nil)
}

@Test func keepsThePinnedWidgetOnTheRight() {
    let ranked = [
        makeActivity("heads-up", widget: "meetings", priority: .urgent),
        makeActivity("music", widget: "music", priority: .background),
        makeActivity("usage", widget: "aiUsage", priority: .low),
    ]
    let sides = pickIslandSides(ranked, isSplit: true, rightWidgetID: "aiUsage")
    #expect(sides.left?.id == "heads-up")
    #expect(sides.right?.id == "usage")
    // The pinned widget's activity moves right even when it ranks first.
    let pinnedTop = pickIslandSides(ranked, isSplit: true, rightWidgetID: "meetings")
    #expect(pinnedTop.left?.id == "music")
    #expect(pinnedTop.right?.id == "heads-up")
    // Alone, it spans both sides; absent, the right goes back to automatic.
    #expect(pickIslandSides(Array(ranked.prefix(1)), isSplit: true, rightWidgetID: "meetings").left?.id == "heads-up")
    #expect(pickIslandSides(ranked, isSplit: true, rightWidgetID: "timer").right?.id == "music")
}
