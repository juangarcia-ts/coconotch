import Foundation

/// How much an activity deserves the closed notch. Higher wins.
public enum ActivityPriority: Int, Comparable, Sendable {
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
/// moves to a new date, such as a heads-up switching to the next meeting under the same id.
public func makeAlertKey(_ activity: ActivitySummary) -> String {
    "\(activity.id)-\(activity.priority.rawValue)-\(activity.sortDate.timeIntervalSince1970)"
}

/// The width of each side of the closed-notch island: the wider side's content, capped so long titles truncate.
public func getIslandSideWidth(_ idealWidths: [CGFloat], maxWidth: CGFloat) -> CGFloat {
    min(idealWidths.max() ?? 0, maxWidth)
}
