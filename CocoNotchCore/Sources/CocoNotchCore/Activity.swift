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
/// user's widget order, then the earliest. Activities from widgets that are not enabled are dropped.
public func rankActivities(_ activities: [ActivitySummary], enabledWidgetIDs: [String]) -> [ActivitySummary] {
    let widgetRank = Dictionary(uniqueKeysWithValues: enabledWidgetIDs.enumerated().map { ($1, $0) })
    return
        activities
        .filter { widgetRank[$0.widgetID] != nil }
        .sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            let lhsRank = widgetRank[lhs.widgetID] ?? 0
            let rhsRank = widgetRank[rhs.widgetID] ?? 0
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.sortDate != rhs.sortDate { return lhs.sortDate < rhs.sortDate }
            return lhs.id < rhs.id
        }
}
