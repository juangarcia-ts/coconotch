import CocoNotchCore
import SwiftUI

extension NotchWidget {
    static let home = NotchWidget(
        id: homeWidgetID,
        title: "Home",
        systemImage: "house",
        makeView: { AnyView(HomeView()) },
        makeSettings: { AnyView(HomeSettings()) }
    )
}

// Stores hidden summaries rather than shown ones, so widgets added later appear on Home by default.
private let hiddenSummaryIDsKey = "home.hiddenSummaryIDs"
// Two keeps every card wide enough for its content in the 680pt panel.
private let maxColumns = 2

private struct HomeView: View {
    @AppStorage(PreferenceKey.widgetPreferences) private var storedWidgetPreferences = ""
    @AppStorage(PreferenceKey.selectedWidget) private var selectedWidgetID = ""
    @AppStorage(hiddenSummaryIDsKey) private var storedHiddenIDs = ""
    @AppStorage(showsMusicKey) private var showsMusic = true
    @AppStorage(showsAskOnHomeKey) private var showsAsk = true
    @State private var dropTargetID: String?

    private var isAskShown: Bool {
        guard #available(macOS 26, *) else { return false }
        return showsAsk
            && getEnabledWidgetIDs(NotchWidget.getPreferences(stored: storedWidgetPreferences)).contains(
                NotchWidget.ask.id)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if showsMusic || isAskShown {
                VStack(spacing: 8) {
                    if showsMusic { NowPlayingPanel() }
                    if #available(macOS 26, *), isAskShown { AskShortcut() }
                }
                .frame(width: 160)
            }
            cards
        }
        // Lets the music panel stretch to the cards' height.
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var cards: some View {
        let widgets = getHomeSummaryIDs(
            getEnabledWidgetIDs(NotchWidget.getPreferences(stored: storedWidgetPreferences)),
            summaryIDs: NotchWidget.summaryIDs,
            hiddenIDs: decodeIDSet(storedHiddenIDs)
        )
        .compactMap(NotchWidget.find(id:))
        if widgets.isEmpty {
            Text("Choose what Home shows in Settings → Home.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            let columnCount = getHomeColumnCount(cardCount: widgets.count, maxColumns: maxColumns)
            let rows = makeRows(widgets, columnCount: columnCount)
            VStack(spacing: 8) {
                ForEach(rows.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(rows[index]) { widget in
                            // Cards follow the widget order, so dragging one also reorders the tabs.
                            SummaryCard(widget: widget, isDropTarget: dropTargetID == widget.id) {
                                selectedWidgetID = widget.id
                            }
                            .modifier(DraggableWidget(id: widget.id, isDraggable: true))
                            .onDrop(
                                of: [widgetDragType],
                                delegate: WidgetDropDelegate(targetID: widget.id, dropTargetID: $dropTargetID)
                            )
                        }
                    }
                    // Lets every card in the row stretch to the tallest one.
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct SummaryCard: View {
    let widget: NotchWidget
    let isDropTarget: Bool
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        // Compact enough that three rows fit in the open panel above the footer.
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                WidgetIcon(widget: widget)
                Text(widget.title)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .opacity(isHovering ? 1 : 0)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            widget.makeSummary?()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.primary.opacity(isHovering ? 0.09 : 0.06))
                .strokeBorder(
                    Color.primary.opacity(isDropTarget ? 0.35 : 0.08), lineWidth: isDropTarget ? 1 : 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open \(widget.title)", open)
        .help("Open \(widget.title)")
    }
}

struct HomeSettings: View {
    @AppStorage(PreferenceKey.widgetPreferences) private var storedWidgetPreferences = ""
    @AppStorage(hiddenSummaryIDsKey) private var storedHiddenIDs = ""
    @AppStorage(showsMusicKey) private var showsMusic = true
    @AppStorage(showsAskOnHomeKey) private var showsAsk = true

    var body: some View {
        Form {
            Section("Summaries") {
                Text(
                    "Home is always the first tab; hide it in Settings → Widgets. Cards follow the widget order there, and clicking one opens its widget."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(getEnabledWidgetIDs(NotchWidget.getPreferences(stored: storedWidgetPreferences)), id: \.self) {
                    id in
                    if let widget = NotchWidget.find(id: id), widget.makeSummary != nil {
                        Toggle(isOn: makeVisibilityBinding(for: widget.id)) {
                            Label {
                                Text(widget.title)
                            } icon: {
                                WidgetIcon(widget: widget)
                            }
                        }
                        widget.makeSummarySettings?()
                            .padding(.leading, 24)
                    }
                }
            }
            Section("Music") {
                Toggle("Show what's playing in Music or Spotify", isOn: $showsMusic)
            }
            Section("Ask") {
                Toggle("Show an Ask field under the music player", isOn: $showsAsk)
                Text("Shown while the Ask widget is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func makeVisibilityBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !decodeIDSet(storedHiddenIDs).contains(id) },
            set: { isVisible in
                var hiddenIDs = decodeIDSet(storedHiddenIDs)
                if isVisible {
                    hiddenIDs.remove(id)
                } else {
                    hiddenIDs.insert(id)
                }
                storedHiddenIDs = encodeIDSet(hiddenIDs)
            }
        )
    }
}
