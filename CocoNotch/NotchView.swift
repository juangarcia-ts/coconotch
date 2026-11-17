import CocoNotchCore
import SwiftUI

struct NotchView: View {
    let notchSize: CGSize
    /// The panel showing this view, so it reacts only to its own panel losing key status.
    let panelID: ObjectIdentifier
    let showSettings: () -> Void

    @State private var isExpanded = false
    /// The top activity whose alert is showing, as an `alertKey`.
    @State private var alertingKey: String?
    @AppStorage(PreferenceKey.selectedWidget) private var selectedWidgetID = ""
    @AppStorage(PreferenceKey.widgetPreferences) private var storedWidgetPreferences = ""
    @AppStorage(PreferenceKey.showsHome) private var showsHome = true
    /// The tab a dragged tab is over, highlighted to show where it will land.
    @State private var dropTargetID: String?
    @AppStorage(PreferenceKey.backgroundStyle) private var backgroundStyle = BackgroundStyle.solid
    @AppStorage(PreferenceKey.backgroundColor) private var backgroundColorData = Data()
    @AppStorage(PreferenceKey.backgroundOpacity) private var backgroundOpacity = 1.0
    @AppStorage(PreferenceKey.expandsOnClick) private var expandsOnClick = false
    @AppStorage(PreferenceKey.notchScale) private var storedNotchScale = 1.0
    @AppStorage(PreferenceKey.showsActivities) private var showsActivities = true
    @AppStorage(PreferenceKey.preferredActivityWidget) private var preferredActivityWidgetID = ""
    @AppStorage(PreferenceKey.staysOpenWhileTyping) private var staysOpenWhileTyping = true
    @AppStorage(shelfOpensOnDragHoverKey) private var opensOnDragHover = true
    @AppStorage(PreferenceKey.widgetShortcuts) private var widgetShortcuts = WidgetShortcutsMode.visible
    @State private var isHovering = false
    /// Whether a drag opened the notch, so it closes again if the drag leaves without dropping.
    @State private var isOpenedByDrag = false
    /// Tells this notch's shelf drop targets apart from another display's.
    @State private var shelfDropScope = UUID()

    private var enabledWidgets: [NotchWidget] {
        getTabIDs(
            enabledIDs: getEnabledWidgetIDs(NotchWidget.getPreferences(stored: storedWidgetPreferences)),
            showsHome: showsHome
        )
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
        .onDrop(
            of: [.item],
            delegate: ShelfDropDelegate(
                scope: shelfDropScope, isEnabled: enabledWidgets.contains { $0.id == NotchWidget.shelf.id })
        )
        .onChange(of: ShelfStore.shared.isDropTargeted(scope: shelfDropScope)) { _, isTargeted in
            handleShelfDrag(isTargeted: isTargeted)
        }
        .environment(\.shelfDropScope, shelfDropScope)
        .onHover { isHovering in
            self.isHovering = isHovering
            // Opening the notch from an activity shows the widget it came from; a low one is too quiet to switch tabs.
            if isHovering, !isExpanded, let activity = activities.first, activity.priority > .low {
                selectedWidgetID = activity.widgetID
            }
            // While typing, the notch closes once the user clicks into another app instead.
            if !isHovering, staysOpenWhileTyping, isTypingInNotch() { return }
            if !isHovering || !expandsOnClick { setExpanded(isHovering) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            if (notification.object as? NotchPanel).map(ObjectIdentifier.init) == panelID, isExpanded, !isHovering {
                setExpanded(false)
            }
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
            width: isExpanded ? 680 : (island == nil ? notchSize.width : nil),
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

    private func handleShelfDrag(isTargeted: Bool) {
        let store = ShelfStore.shared
        if isTargeted {
            store.didDrop = false
            applyShelfDragChange(isTargeted: true)
            return
        }
        // Moving from the notch onto a shelf leaves no target for a moment, so this waits before deciding.
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !store.isDropTargeted(scope: shelfDropScope) else { return }
            applyShelfDragChange(isTargeted: false)
            isOpenedByDrag = false
        }
    }

    private func applyShelfDragChange(isTargeted: Bool) {
        switch getShelfDragChange(
            isTargeted: isTargeted, isExpanded: isExpanded, opensOnDragHover: opensOnDragHover,
            isOpenedByDrag: isOpenedByDrag, didDrop: ShelfStore.shared.didDrop, isHovering: isHovering)
        {
        case .show:
            selectedWidgetID = NotchWidget.shelf.id
            if !isExpanded {
                isOpenedByDrag = true
                setExpanded(true)
            }
        case .close: setExpanded(false)
        case .leaveToHover: isHovering = true
        case .none: break
        }
    }

    private func setExpanded(_ isExpanded: Bool) {
        // A click into a text field makes the panel key; closing gives the keyboard back to the app the user was in.
        if !isExpanded, NSApp.keyWindow is NotchPanel { NSWorkspace.shared.frontmostApplication?.activate() }
        // Opening takes the keyboard so widget shortcuts reach the notch instead of the app underneath.
        if isExpanded, widgetShortcuts != .disabled {
            NSApp.windows.first { ObjectIdentifier($0) == panelID }?.makeKey()
        }
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) { self.isExpanded = isExpanded }
    }

    private func isTypingInNotch() -> Bool {
        // A focused text field puts its shared field editor, an NSTextView, first in line for keys.
        (NSApp.keyWindow as? NotchPanel)?.firstResponder is NSTextView
    }

    private func expandedContent(activities: [NotchActivity]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(Array(enabledWidgets.enumerated()), id: \.element.id) { index, widget in
                    let digit = widgetShortcuts == .disabled ? nil : getWidgetShortcutDigit(index: index)
                    Button {
                        selectedWidgetID = widget.id
                    } label: {
                        WidgetIcon(widget: widget)
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
                            .overlay(alignment: .bottom) {
                                if widgetShortcuts == .visible, let digit {
                                    Text(verbatim: "⌘\(digit)")
                                        .font(.system(size: 8).monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                        .offset(y: 9)
                                }
                            }
                            .background(
                                widget.id == selectedWidget.id ? Color.primary.opacity(0.15) : .clear,
                                in: Capsule()
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    // Works once the notch has keyboard focus, so typing in other apps never switches widgets.
                    .keyboardShortcut(digit.map { KeyboardShortcut(KeyEquivalent($0), modifiers: .command) })
                    .help(digit.map { "\(widget.title) (⌘\($0))" } ?? widget.title)
                    .background(
                        Capsule().strokeBorder(
                            Color.primary.opacity(dropTargetID == widget.id ? 0.35 : 0), lineWidth: 1)
                    )
                    // Home can't be dragged; dropping a tab on it moves that tab to the front.
                    .modifier(
                        DraggableWidget(id: widget.id, isDraggable: widget.id != homeWidgetID)
                    )
                    .onDrop(
                        of: [widgetDragType],
                        delegate: WidgetDropDelegate(targetID: widget.id, dropTargetID: $dropTargetID)
                    )
                }
                // The empty space after the tabs takes drops too, so a tab can be moved to the end.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onDrop(
                        of: [widgetDragType],
                        delegate: WidgetDropDelegate(targetID: widgetListEndID, dropTargetID: $dropTargetID)
                    )
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
                .padding(.top, getWidgetTopPadding(widgetShortcuts: widgetShortcuts))
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity)
                // A tall widget is cut here rather than pushing the footer past the panel's edge.
                .frame(
                    maxHeight: getWidgetMaxHeight(
                        panelHeight: NotchPanel.baseSize.height,
                        tabBarHeight: notchSize.height + 8,
                        footerHeight: NotchFooter.height
                    ),
                    alignment: .top
                )
                .clipped()

            NotchFooter()
                .padding(.horizontal, 24)
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
