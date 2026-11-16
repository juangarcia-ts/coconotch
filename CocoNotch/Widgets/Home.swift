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
private let maxColumnsKey = "home.maxColumns"
private let defaultMaxColumns = 3

private struct HomeView: View {
    @AppStorage(PreferenceKey.widgetPreferences) private var storedWidgetPreferences = ""
    @AppStorage(PreferenceKey.selectedWidget) private var selectedWidgetID = ""
    @AppStorage(hiddenSummaryIDsKey) private var storedHiddenIDs = ""
    @AppStorage(maxColumnsKey) private var maxColumns = defaultMaxColumns

    var body: some View {
        let widgets = getHomeSummaryIDs(
            NotchWidget.getPreferences(stored: storedWidgetPreferences).map(\.id),
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
            VStack(spacing: 10) {
                ForEach(rows.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(rows[index]) { widget in
                            SummaryCard(widget: widget) { selectedWidgetID = widget.id }
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
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: widget.systemImage)
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
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.primary.opacity(isHovering ? 0.09 : 0.06))
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
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
    @AppStorage(maxColumnsKey) private var maxColumns = defaultMaxColumns

    var body: some View {
        Form {
            Picker("Cards per row", selection: $maxColumns) {
                ForEach(1...3, id: \.self) { Text("\($0)").tag($0) }
            }
            Section("Summaries") {
                Text(
                    "Home is always the first tab; hide it in Settings → Widgets. Cards follow the widget order there, and clicking one opens its widget."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(NotchWidget.getPreferences(stored: storedWidgetPreferences)) { preference in
                    if let widget = NotchWidget.find(id: preference.id), widget.makeSummary != nil {
                        Toggle(isOn: makeVisibilityBinding(for: widget.id)) {
                            Label(widget.title, systemImage: widget.systemImage)
                        }
                        widget.makeSummarySettings?()
                            .padding(.leading, 24)
                    }
                }
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
