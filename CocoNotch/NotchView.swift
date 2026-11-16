import CocoNotchCore
import SwiftUI

struct NotchView: View {
    let notchSize: CGSize
    let showSettings: () -> Void

    @State private var isExpanded = false
    /// The top activity whose alert is showing, as an `alertKey`.
    @State private var alertingKey: String?
    @AppStorage(PreferenceKey.selectedWidget) private var selectedWidgetID = ""
    @AppStorage(PreferenceKey.widgetPreferences) private var storedWidgetPreferences = ""
    @AppStorage(PreferenceKey.backgroundStyle) private var backgroundStyle = BackgroundStyle.solid
    @AppStorage(PreferenceKey.backgroundColor) private var backgroundColorData = Data()
    @AppStorage(PreferenceKey.backgroundOpacity) private var backgroundOpacity = 1.0
    @AppStorage(PreferenceKey.expandsOnClick) private var expandsOnClick = false
    @AppStorage(PreferenceKey.notchScale) private var storedNotchScale = 1.0
    @AppStorage(PreferenceKey.showsActivities) private var showsActivities = true
    @AppStorage(PreferenceKey.preferredActivityWidget) private var preferredActivityWidgetID = ""

    private var enabledWidgets: [NotchWidget] {
        getEnabledWidgetIDs(NotchWidget.getPreferences(stored: storedWidgetPreferences))
            .compactMap { NotchWidget.find(id: $0) }
    }

    /// Activities from enabled widgets, winner first.
    private var rankedActivities: [NotchActivity] {
        guard showsActivities else { return [] }
        return ActivityCenter.shared.getRanked(
            enabledWidgetIDs: enabledWidgets.map(\.id),
            preferredWidgetID: preferredActivityWidgetID.isEmpty ? nil : preferredActivityWidgetID
        )
    }

    // Falls back to the first enabled widget when the last selected one was switched off.
    private var selectedWidget: NotchWidget {
        let enabledIDs = enabledWidgets.map(\.id)
        let id = resolveSelectedWidgetID(selectedWidgetID, enabledIDs: enabledIDs)
        // Decoding always leaves one widget enabled, so this fallback only covers an empty widget list.
        return id.flatMap { NotchWidget.find(id: $0) } ?? NotchWidget.all[0]
    }

    private var usesDarkText: Bool {
        guard isExpanded, backgroundStyle == .solid else { return false }
        let color = Color.Resolved.decode(colorData: backgroundColorData)
        return shouldUseDarkText(
            linearRed: Double(color.linearRed),
            linearGreen: Double(color.linearGreen),
            linearBlue: Double(color.linearBlue)
        )
    }

    var body: some View {
        let radius: CGFloat = isExpanded || alertingKey != nil ? 28 : 10
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius)

        // Only the open panel scales; the closed notch has to match the physical one exactly.
        let scale = isExpanded ? clampNotchScale(storedNotchScale) : 1
        let activities = rankedActivities
        let alertKey = activities.first.flatMap { $0.makeAlert == nil ? nil : makeAlertKey($0.summary) }

        ScaledLayout(scale: scale) {
            panel(shape: shape, activities: activities, isAlerting: alertKey != nil && alertKey == alertingKey)
                .scaleEffect(scale, anchor: .topLeading)
        }
        .animation(.spring(duration: 0.4, bounce: 0.25), value: activities.first?.id)
        .animation(.spring(duration: 0.5, bounce: 0.35), value: alertingKey)
        .onChange(of: alertKey, initial: true) { _, key in showAlert(key: key) }
        .contentShape(Rectangle())
        .onHover { isHovering in
            // Opening the notch from an activity shows the widget it came from.
            if isHovering, !isExpanded, let activity = activities.first { selectedWidgetID = activity.widgetID }
            if !isHovering || !expandsOnClick { setExpanded(isHovering) }
        }
        .onTapGesture {
            if expandsOnClick && !isExpanded { setExpanded(true) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, usesDarkText ? .light : .dark)
    }

    private func panel(shape: UnevenRoundedRectangle, activities: [NotchActivity], isAlerting: Bool) -> some View {
        let island = isExpanded ? nil : activities.first
        let isAlerting = island != nil && isAlerting
        return ZStack(alignment: .top) {
            if !isExpanded {
                shape.fill(.black)
            } else if backgroundStyle == .blur {
                BehindWindowBlur()
                    .clipShape(shape)
                    .opacity(backgroundOpacity)
            } else {
                shape.fill(Color(colorData: backgroundColorData).opacity(backgroundOpacity))
            }
            if isExpanded {
                expandedContent(activities: activities)
                    .transition(.opacity)
            } else if let island {
                ActivityIsland(
                    activity: island,
                    notchSize: notchSize,
                    otherCount: activities.count - 1,
                    isAlerting: isAlerting
                )
                .transition(.opacity)
            }
        }
        // Expanded, the height follows the widget's content; with an activity, the closed notch widens to fit it.
        .frame(
            width: isExpanded ? 600 : (island == nil ? notchSize.width : nil),
            height: isExpanded || isAlerting ? nil : notchSize.height
        )
        .fixedSize(horizontal: island != nil, vertical: isExpanded || isAlerting)
    }

    /// Shows the new top activity's alert, then folds it back into the island.
    private func showAlert(key: String?) {
        alertingKey = key
        guard let key else { return }
        Task {
            try? await Task.sleep(for: .seconds(6))
            if alertingKey == key { alertingKey = nil }
        }
    }

    private func setExpanded(_ isExpanded: Bool) {
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) { self.isExpanded = isExpanded }
    }

    private func expandedContent(activities: [NotchActivity]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(enabledWidgets) { widget in
                    Button {
                        selectedWidgetID = widget.id
                    } label: {
                        Image(systemName: widget.systemImage)
                            .frame(width: 40, height: notchSize.height - 6)
                            // Marks widgets with a live activity, since the closed notch shows only one.
                            .overlay(alignment: .topTrailing) {
                                if activities.contains(where: { $0.widgetID == widget.id }) {
                                    Circle()
                                        .fill(.orange)
                                        .frame(width: 6, height: 6)
                                        .padding(6)
                                }
                            }
                            .background(
                                widget.id == selectedWidget.id ? Color.primary.opacity(0.15) : .clear,
                                in: Capsule()
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(widget.title)
                }
                Spacer()
                Button("Settings", systemImage: "gearshape", action: showSettings)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .frame(width: 40, height: notchSize.height - 6)
                    .contentShape(Capsule())
                    .help("Settings")
            }
            .frame(height: notchSize.height)
            .padding(.horizontal, 24)
            .padding(.top, 8)

            selectedWidget.makeView()
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.primary)
        // Content taller than the panel would be cut off by the window edge, so clip it at the panel's height instead.
        .frame(maxHeight: NotchPanel.baseSize.height, alignment: .top)
        .clipped()
    }
}

/// SwiftUI materials only blur the window's own content; this blurs the desktop behind the panel.
private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Lays its child out at 1/scale of the space and reports scale × the child's size, so a child drawn with
/// `.scaleEffect(scale, anchor: .topLeading)` takes up the room it appears to. `scaleEffect` alone changes only the
/// drawing, not the layout, so the panel would overflow or leave gaps.
private struct ScaledLayout: Layout {
    let scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(
            ProposedViewSize(width: proposal.width.map { $0 / scale }, height: proposal.height.map { $0 / scale })
        )
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width / scale, height: bounds.height / scale)
        )
    }
}
