import CocoNotchCore
import SwiftUI

/// Something a widget wants to show in the closed notch, like an iOS Live Activity: a view on each side of the
/// camera. Widgets post and remove these through `ActivityCenter`; the notch decides which one is shown.
struct NotchActivity: Identifiable {
    let id: String
    let widgetID: String
    let priority: ActivityPriority
    /// Earlier comes first within the same widget, for example the sooner meeting.
    let sortDate: Date
    let makeLeading: () -> AnyView
    let makeTrailing: () -> AnyView
    /// Shown as a dismiss button in the open notch; nil when the activity can't be dismissed.
    var dismiss: (() -> Void)? = nil

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
    func getRanked(enabledWidgetIDs: [String]) -> [NotchActivity] {
        rankActivities(activities.values.map(\.summary), enabledWidgetIDs: enabledWidgetIDs)
            .compactMap { activities[$0.id] }
    }

    #if DEBUG
        /// Launch with `-CocoNotchDemoActivities YES` to see the island without waiting for a real activity.
        func postDemoActivitiesIfRequested() {
            guard UserDefaults.standard.bool(forKey: "CocoNotchDemoActivities") else { return }
            for (index, widgetID) in NotchWidget.all.map(\.id).enumerated() {
                let id = "demo-\(widgetID)"
                post(
                    NotchActivity(
                        id: id,
                        widgetID: widgetID,
                        priority: index == 0 ? .urgent : .background,
                        sortDate: .now,
                        makeLeading: { AnyView(Label("Demo", systemImage: "sparkles")) },
                        makeTrailing: { AnyView(Text(widgetID).foregroundStyle(.secondary)) },
                        dismiss: { [weak self] in self?.remove(id: id) }
                    )
                )
            }
        }
    #endif
}

/// The closed notch widened to show an activity on both sides of the camera.
struct ActivityIsland: View {
    let activity: NotchActivity
    let notchSize: CGSize
    let otherCount: Int

    // Both sides are the same width so the camera stays centered between them.
    static let sideWidth: CGFloat = 130

    var body: some View {
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
                        .help("\(otherCount) more in the open notch")
                }
            }
            .padding(.trailing, 14)
            .frame(width: Self.sideWidth, alignment: .trailing)
        }
        .font(.callout.weight(.medium))
        .frame(height: notchSize.height)
    }
}

/// One activity in the open notch's list, with a dismiss button when the activity allows it.
struct ActivityRow: View {
    let activity: NotchActivity

    var body: some View {
        HStack(spacing: 10) {
            activity.makeLeading()
            Spacer()
            activity.makeTrailing()
            if let dismiss = activity.dismiss {
                Button("Dismiss", systemImage: "xmark.circle.fill", action: dismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Dismiss")
            }
        }
        .lineLimit(1)
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
