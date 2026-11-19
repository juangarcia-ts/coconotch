import Foundation

/// How much an activity deserves the closed notch. Higher wins.
public enum ActivityPriority: Int, Comparable, Sendable {
    /// Shown only when nothing else is, such as the next meeting later today.
    case low
    /// Ongoing context, such as music playing.
    case background
    /// Something coming up, such as a meeting countdown.
    case normal
    /// Needs attention now, such as a meeting that is starting.
    case urgent

    public static func < (lhs: ActivityPriority, rhs: ActivityPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// What the ranking needs to know about an activity; the views it shows stay in the app.
public struct ActivitySummary: Equatable, Sendable {
    public let id: String
    public let widgetID: String
    public let priority: ActivityPriority
    /// Earlier comes first within the same widget, for example the sooner meeting.
    public let sortDate: Date

    public init(id: String, widgetID: String, priority: ActivityPriority, sortDate: Date) {
        self.id = id
        self.widgetID = widgetID
        self.priority = priority
        self.sortDate = sortDate
    }
}

/// Orders activities so the first one gets the closed notch: highest priority, then the widget higher in the
/// user's widget order, then the earliest. A preferred widget, if the user picked one, beats everything else.
/// Activities from widgets that are not enabled are dropped.
public func rankActivities(
    _ activities: [ActivitySummary],
    enabledWidgetIDs: [String],
    preferredWidgetID: String? = nil
) -> [ActivitySummary] {
    let widgetRank = Dictionary(uniqueKeysWithValues: enabledWidgetIDs.enumerated().map { ($1, $0) })
    return
        activities
        .filter { widgetRank[$0.widgetID] != nil }
        .sorted { lhs, rhs in
            let isLhsPreferred = lhs.widgetID == preferredWidgetID
            if isLhsPreferred != (rhs.widgetID == preferredWidgetID) { return isLhsPreferred }
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            let lhsRank = widgetRank[lhs.widgetID] ?? 0
            let rhsRank = widgetRank[rhs.widgetID] ?? 0
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.sortDate != rhs.sortDate { return lhs.sortDate < rhs.sortDate }
            return lhs.id < rhs.id
        }
}

/// Identifies one alert-worthy state of an activity: it changes when the activity appears, its priority rises, or it
/// moves to a new date, such as a heads-up switching to the next meeting under the same id. Stickiness is part of it,
/// so turning stickiness off restarts the alert's fold-back timer.
public func makeAlertKey(_ activity: ActivitySummary, isSticky: Bool) -> String {
    "\(activity.id)-\(activity.priority.rawValue)-\(activity.sortDate.timeIntervalSince1970)-\(isSticky)"
}

/// The width of each side of the closed-notch island: the wider side's content, capped so long titles truncate, but
/// never below what a side can't shrink under, such as a countdown beside a title's first letters.
public func getIslandSideWidth(_ idealWidths: [CGFloat], minWidths: [CGFloat] = [], maxWidth: CGFloat) -> CGFloat {
    max(min(idealWidths.max() ?? 0, maxWidth), minWidths.max() ?? 0)
}

/// The "+N" beside the island: noteworthy activities on neither side.
public func countHiddenActivities(_ activities: [ActivitySummary], shownIDs: [String?]) -> Int {
    activities.filter { !shownIDs.contains($0.id) && isActivityNoteworthy($0) }.count
}

/// Whether an activity deserves notice beyond the closed notch: a tab switch on hover, a dot on its tab, a "+N".
public func isActivityNoteworthy(_ activity: ActivitySummary) -> Bool {
    activity.priority > .low
}

/// The tab hovering the closed notch opens: the top activity's widget, unless it is too quiet to switch tabs.
public func getHoverWidgetID(_ topActivity: ActivitySummary?) -> String? {
    guard let topActivity, isActivityNoteworthy(topActivity) else { return nil }
    return topActivity.widgetID
}

/// The activities on each side of the camera. A split notch gives the right side to `rightWidgetID` whenever it has an
/// activity, and otherwise to the next activity from another widget than the left's, so two meetings never take both
/// sides. Quiet ones count, as a split notch has room for them. With nothing for the right, the left spans both sides.
public func pickIslandSides(
    _ ranked: [ActivitySummary], isSplit: Bool, rightWidgetID: String?
) -> (left: ActivitySummary?, right: ActivitySummary?) {
    guard isSplit else { return (ranked.first, nil) }
    if let pinned = ranked.first(where: { $0.widgetID == rightWidgetID }) {
        guard let left = ranked.first(where: { $0.widgetID != rightWidgetID }) else { return (pinned, nil) }
        return (left, pinned)
    }
    let left = ranked.first
    return (left, ranked.dropFirst().first { $0.widgetID != left?.widgetID })
}
