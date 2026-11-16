import CocoNotchCore
import SwiftUI

/// Something a widget wants to show in the closed notch, like an iOS Live Activity: a view on each side of the
/// camera. Widgets post and remove these through `ActivityCenter`; the notch decides which one is shown, and the
/// widget's own tab shows the details and any controls, such as dismissing it.
struct NotchActivity: Identifiable {
    let id: String
    let widgetID: String
    let priority: ActivityPriority
    /// Earlier comes first within the same widget, for example the sooner meeting.
    let sortDate: Date
    let makeLeading: () -> AnyView
    let makeTrailing: () -> AnyView
    /// A bigger view shown under the island for a few seconds when the activity appears or its priority rises.
    var makeAlert: (() -> AnyView)?

    var summary: ActivitySummary {
        ActivitySummary(id: id, widgetID: widgetID, priority: priority, sortDate: sortDate)
    }
}

@Observable
final class ActivityCenter {
    static let shared = ActivityCenter()

    private(set) var activities: [String: NotchActivity] = [:]

    func post(_ activity: NotchActivity) {
        activities[activity.id] = activity
    }

    func remove(id: String) {
        activities[id] = nil
    }

    /// The activities to show, winner first; see `rankActivities` for the rules.
    func getRanked(enabledWidgetIDs: [String], preferredWidgetID: String?) -> [NotchActivity] {
        rankActivities(
            activities.values.map(\.summary),
            enabledWidgetIDs: enabledWidgetIDs,
            preferredWidgetID: preferredWidgetID
        )
        .compactMap { activities[$0.id] }
    }
}

/// The closed notch widened to show an activity on both sides of the camera.
struct ActivityIsland: View {
    let activity: NotchActivity
    let notchSize: CGSize
    let otherCount: Int
    let isAlerting: Bool

    // Both sides are the same width so the camera stays centered between them.
    static let sideWidth: CGFloat = 140

    var body: some View {
        VStack(spacing: 0) {
            row
            if isAlerting, let makeAlert = activity.makeAlert {
                makeAlert()
                    .frame(width: Self.sideWidth * 2 + notchSize.width, alignment: .leading)
                    .transition(.opacity)
            }
        }
    }

    private var row: some View {
        HStack(spacing: 0) {
            activity.makeLeading()
                .lineLimit(1)
                .padding(.leading, 14)
                .frame(width: Self.sideWidth, alignment: .leading)
            Color.clear
                .frame(width: notchSize.width)
            HStack(spacing: 6) {
                activity.makeTrailing()
                    .lineLimit(1)
                if otherCount > 0 {
                    Text("+\(otherCount)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .background(Color.primary.opacity(0.2), in: Capsule())
                        .help("\(otherCount) more; their widgets' tabs are marked with a dot")
                }
            }
            .padding(.trailing, 14)
            .frame(width: Self.sideWidth, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .frame(height: notchSize.height)
    }
}
