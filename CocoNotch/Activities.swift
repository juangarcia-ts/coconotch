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

    static let maxSideWidth: CGFloat = 140

    var body: some View {
        VStack(spacing: 0) {
            row
            if isAlerting, let makeAlert = activity.makeAlert {
                makeAlert()
                    .frame(maxWidth: Self.maxSideWidth * 2 + notchSize.width, alignment: .leading)
                    // Spans the island's width without widening it past the row, so both line up.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
    }

    private var row: some View {
        IslandLayout(gapWidth: notchSize.width, maxSideWidth: Self.maxSideWidth) {
            activity.makeLeading()
                .lineLimit(1)
                .padding(.leading, 14)
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
        }
        .font(.caption.weight(.semibold))
        .frame(height: notchSize.height)
    }
}

/// Places the leading view, a gap as wide as the notch, then the trailing view. Both sides take the wider side's
/// width, so the camera stays centered and the island is only as wide as its content.
private struct IslandLayout: Layout {
    let gapWidth: CGFloat
    let maxSideWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(
            width: getSideWidth(subviews) * 2 + gapWidth,
            height: proposal.replacingUnspecifiedDimensions().height
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let side = ProposedViewSize(width: getSideWidth(subviews), height: bounds.height)
        subviews.first?.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: side)
        subviews.last?.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: side)
    }

    private func getSideWidth(_ subviews: Subviews) -> CGFloat {
        getIslandSideWidth(subviews.map { $0.sizeThatFits(.unspecified).width }, maxWidth: maxSideWidth)
    }
}
