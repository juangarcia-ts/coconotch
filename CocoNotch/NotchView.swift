import CocoNotchCore
import SwiftUI

struct NotchView: View {
    let notchSize: CGSize
    let cameraHousingHeight: CGFloat
    /// The panel showing this view, so it reacts only to its own panel losing key status.
    let panelID: ObjectIdentifier
    let showSettings: (SettingsPage) -> Void

    @State private var isExpanded = false
    /// The top activity whose alert is showing, as an `alertKey`.
    @State private var alertingKey: String?
    @State private var alertTask: Task<Void, Never>?
    @AppStorage(PreferenceKey.selectedWidget) private var selectedWidgetID = ""
    @AppStorage(PreferenceKey.widgetPreferences) private var storedWidgetPreferences = ""
    @AppStorage(PreferenceKey.showsHome) private var showsHome = true
    /// The tab a dragged tab is over, highlighted to show where it will land.
    @State private var dropTargetID: String?
    @AppStorage(PreferenceKey.backgroundStyle) private var backgroundStyle = BackgroundStyle.blur
    @AppStorage(PreferenceKey.backgroundColor) private var backgroundColorData = Data()
    @AppStorage(PreferenceKey.backgroundOpacity) private var backgroundOpacity = 0.85
    @AppStorage(PreferenceKey.expandsOnClick) private var expandsOnClick = false
    @AppStorage(PreferenceKey.notchScale) private var storedNotchScale = 1.0
    @AppStorage(PreferenceKey.showsActivities) private var showsActivities = true
    @AppStorage(PreferenceKey.preferredActivityWidget) private var preferredActivityWidgetID = ""
    @AppStorage(PreferenceKey.showsTwoActivities) private var showsTwoActivities = true
    @AppStorage(PreferenceKey.rightActivityWidget) private var rightActivityWidgetID = ""
    @AppStorage(PreferenceKey.staysOpenWhileTyping) private var staysOpenWhileTyping = true
    @AppStorage(shelfOpensOnDragHoverKey) private var opensOnDragHover = true
    @AppStorage(PreferenceKey.widgetShortcuts) private var widgetShortcuts = WidgetShortcutsMode.visible
    @State private var isHovering = false
    /// Whether a drag opened the notch, so it closes again if the drag leaves without dropping.
    @State private var isOpenedByDrag = false
    /// Whether files are being dragged over the notch, held a moment past each gap between its drop targets.
    @State private var isFileDragOver = false
    /// Set once a file picker opens, so the notch is still there to show what was picked: it closes only after the
    /// pointer comes back and leaves, or on a click elsewhere.
    @State private var isHeldOpen = false
    @AppStorage(convertShowsDropStripKey) private var showsConvertDropStrip = true
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
        let scale = isExpanded ? getAppliedNotchScale(storedNotchScale) : 1
        let activities = rankedActivities
        let alertKey = activities.first.flatMap {
            $0.makeAlert == nil ? nil : makeAlertKey($0.summary, isSticky: $0.isAlertSticky)
        }
        // Opening the notch would hide a sticky alert's buttons, so hover and click leave it closed.
        let isStickyAlertShowing = alertKey != nil && alertKey == alertingKey && activities.first?.isAlertSticky == true

        ScaledLayout(scale: scale) {
            panel(shape: shape, activities: activities, isAlerting: alertKey != nil && alertKey == alertingKey)
                .scaleEffect(scale, anchor: .topLeading)
        }
        .animation(.spring(duration: 0.4, bounce: 0.25), value: activities.first?.id)
        .animation(.spring(duration: 0.5, bounce: 0.35), value: alertingKey)
        .onChange(of: alertKey, initial: true) { _, key in
            showAlert(key: key, isSticky: activities.first?.isAlertSticky == true)
        }
        .contentShape(Rectangle())
        .onDrop(
            of: [.item],
            // While Convert is open, a drop anywhere on the notch goes to it.
            delegate: ShelfDropDelegate(
                scope: shelfDropScope,
                isEnabled: enabledWidgets.contains { $0.id == NotchWidget.shelf.id } || isConvertOpen,
                isConvert: isConvertOpen)
        )
        .onChange(of: ShelfStore.shared.isDropTargeted(scope: shelfDropScope)) { _, isTargeted in
            handleShelfDrag(isTargeted: isTargeted)
        }
        .environment(\.shelfDropScope, shelfDropScope)
        .environment(\.showSettings, ShowSettingsAction(action: openSettings))
        .onHover { isHovering in
            self.isHovering = isHovering
            if isHovering, isStickyAlertShowing { return }
            if isHovering { isHeldOpen = false }
            // Opening the notch from an activity shows the widget it came from.
            if isHovering, !isExpanded, let widgetID = getHoverWidgetID(activities.first?.summary) {
                selectedWidgetID = widgetID
            }
            // While typing, the notch closes once the user clicks into another app instead.
            if !isHovering, staysOpenWhileTyping, isTypingInNotch() { return }
            if !isHovering, FilePicker.shared.openerID == panelID || isHeldOpen { return }
            // An alert dropping under a resting pointer isn't a hover; opening would take the keyboard. A click opens it.
            if isHovering, alertingKey != nil { return }
            if !isHovering || !expandsOnClick { setExpanded(isHovering) }
        }
        // A menu's items can hang past the notch, so picking one leaves the pointer outside it. A menu opened from the
        // open notch keeps it open, and taking the keyboard lets a click elsewhere close it, as the file picker does.
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            guard isExpanded, isHovering else { return }
            isHeldOpen = true
            NSApp.windows.first { ObjectIdentifier($0) == panelID }?.makeKey()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            if (notification.object as? NotchPanel).map(ObjectIdentifier.init) == panelID, isExpanded, !isHovering,
                FilePicker.shared.openerID != panelID
            {
                isHeldOpen = false
                setExpanded(false)
            }
        }
        .onTapGesture {
            // Without click-to-open, a click still opens it when an alert came up under a resting pointer.
            guard !isExpanded, !isStickyAlertShowing else { return }
            if let widgetID = getHoverWidgetID(activities.first?.summary) { selectedWidgetID = widgetID }
            setExpanded(true)
        }
        // Stays open to show what was picked; taking the keyboard lets a click elsewhere close it, as the pointer may
        // not come back over it.
        .onChange(of: FilePicker.shared.openerID) { oldID, newID in
            if newID == panelID {
                isHeldOpen = true
            } else if oldID == panelID, isExpanded {
                NSApp.windows.first { ObjectIdentifier($0) == panelID }?.makeKey()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hotKeyPressed)) { notification in
            guard let widgetID = notification.object as? String, isHotKeyTarget() else { return }
            let shouldOpen = shouldOpenNotchForHotKey(
                widgetID: widgetID, isExpanded: isExpanded, selectedWidgetID: selectedWidget.id)
            if !widgetID.isEmpty { selectedWidgetID = widgetID }
            setExpanded(shouldOpen)
            // Taking the keyboard lets a click elsewhere close it, as the pointer may never have been over it.
            if shouldOpen { NSApp.windows.first { ObjectIdentifier($0) == panelID }?.makeKey() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // AppKit insets the safe area by the camera housing, which would push the notch below the physical one.
        .ignoresSafeArea()
        .environment(\.colorScheme, usesDarkText ? .light : .dark)
    }

    private func panel(shape: UnevenRoundedRectangle, activities: [NotchActivity], isAlerting: Bool) -> some View {
        let sides = pickIslandSides(
            activities.map(\.summary), isSplit: showsTwoActivities,
            rightWidgetID: rightActivityWidgetID.isEmpty ? nil : rightActivityWidgetID)
        let island = isExpanded ? nil : activities.first { $0.id == sides.left?.id }
        let partner = activities.first { $0.id == sides.right?.id }
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
                expandedContent(
                    markedWidgetIDs: getMarkedWidgetIDs(activities.map(\.summary), sides: [sides.left, sides.right])
                )
                .transition(.opacity)
            } else if let island {
                ActivityIsland(
                    activity: island,
                    partner: partner,
                    notchSize: notchSize,
                    otherCount: countHiddenActivities(activities.map(\.summary), shownIDs: [island.id, partner?.id]),
                    makeAlert: isAlerting ? activities.first?.makeAlert : nil
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
    private func showAlert(key: String?, isSticky: Bool) {
        alertingKey = key
        alertTask?.cancel()
        guard let key, !isSticky else { return }
        alertTask = Task {
            guard (try? await Task.sleep(for: .seconds(10))) != nil else { return }
            if alertingKey == key { alertingKey = nil }
        }
    }

    private var isConvertOpen: Bool {
        isExpanded && selectedWidget.id == NotchWidget.convert.id
    }

    private func handleShelfDrag(isTargeted: Bool) {
        let store = ShelfStore.shared
        if isTargeted {
            isFileDragOver = true
            store.didDrop = false
            applyShelfDragChange(isTargeted: true)
            return
        }
        // Moving from the notch onto a shelf leaves no target for a moment, so this waits before deciding.
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !store.isDropTargeted(scope: shelfDropScope) else { return }
            isFileDragOver = false
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
            if !isConvertOpen { selectedWidgetID = NotchWidget.shelf.id }
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
        // Opening takes the keyboard so widget shortcuts reach the notch instead of the app underneath.
        if isExpanded, widgetShortcuts != .disabled {
            NSApp.windows.first { ObjectIdentifier($0) == panelID }?.makeKey()
        }
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) { self.isExpanded = isExpanded }
        // A click into a text field makes the panel key; closing gives the keyboard back to the app the user was in.
        // After the state change, so the panel's resign-key handler sees it already closed and doesn't close it again.
        if !isExpanded { (NSApp.keyWindow as? NotchPanel)?.returnKeyFocus() }
    }

    private func openSettings(_ page: SettingsPage) {
        // Settings first, so closing finds it key and doesn't deactivate the app it's activating.
        showSettings(page)
        setExpanded(false)
    }

    /// With a notch on every display, a hotkey opens only the one under the pointer.
    private func isHotKeyTarget() -> Bool {
        let screens = NSScreen.screens
        let panels = NSApp.windows.compactMap { $0 as? NotchPanel }
        let ownScreen = panels.first { ObjectIdentifier($0) == panelID }?.screen
        guard let ownDisplay = ownScreen.flatMap({ screens.firstIndex(of: $0) }) else { return false }
        return shouldHandleHotKey(
            ownDisplay: ownDisplay,
            panelDisplays: panels.compactMap { $0.screen.flatMap { screens.firstIndex(of: $0) } }.sorted(),
            pointerDisplay: screens.firstIndex { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
    }

    private func isTypingInNotch() -> Bool {
        // A focused text field puts its shared field editor, an NSTextView, first in line for keys.
        (NSApp.keyWindow as? NotchPanel)?.firstResponder is NSTextView
    }

    private func expandedContent(markedWidgetIDs: Set<String>) -> some View {
        let housingInset = getCameraHousingInset(
            height: cameraHousingHeight, notchScale: getAppliedNotchScale(storedNotchScale))
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(Array(enabledWidgets.enumerated()), id: \.element.id) { index, widget in
                    let shortcut = widgetShortcuts == .disabled ? nil : getWidgetTabShortcut(index: index)
                    Button {
                        selectedWidgetID = widget.id
                    } label: {
                        WidgetIcon(widget: widget)
                            .frame(width: 40, height: notchSize.height - 6)
                            // Marks widgets with a live activity, since hovering the closed notch opens only one.
                            .overlay(alignment: .topTrailing) {
                                if markedWidgetIDs.contains(widget.id) {
                                    Circle()
                                        .fill(.orange)
                                        .frame(width: 6, height: 6)
                                        .padding(6)
                                }
                            }
                            .overlay(alignment: .bottom) {
                                if widgetShortcuts == .visible, let shortcut {
                                    Text(verbatim: shortcut.label)
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
                    .keyboardShortcut(
                        shortcut.map {
                            KeyboardShortcut(
                                KeyEquivalent($0.digit), modifiers: $0.usesOption ? [.command, .option] : .command)
                        }
                    )
                    .help(shortcut.map { "\(widget.title) (\($0.label))" } ?? widget.title)
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
            }
            .frame(height: notchSize.height)
            .padding(.horizontal, 24)
            // Below a physical notch, so the camera housing doesn't hide the middle tabs.
            .padding(.top, 8 + housingInset)

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

            // While files are dragged, the footer gives its place to a way to convert them instead of shelving them.
            if shouldShowConvertDropStrip(
                isFileDragOver: isFileDragOver, isSettingOn: showsConvertDropStrip, isConvertOpen: isConvertOpen,
                isConvertEnabled: enabledWidgets.contains { $0.id == NotchWidget.convert.id },
                isConverting: ConvertStore.shared.isRunning)
            {
                ConvertDropStrip()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
            } else {
                NotchFooter()
                    .padding(.horizontal, 24)
            }
        }
        .foregroundStyle(.primary)
        // Content taller than the panel would be cut off by the window edge, so clip it at the panel's height instead.
        .frame(maxHeight: NotchPanel.baseSize.height + housingInset, alignment: .top)
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
