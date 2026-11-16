import CocoNotchCore
import SwiftUI

extension NotchWidget {
    static let home = NotchWidget(
        id: "home",
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
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: columnCount),
                spacing: 10
            ) {
                ForEach(widgets) { widget in
                    SummaryCard(widget: widget) { selectedWidgetID = widget.id }
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
        VStack(alignment: .leading, spacing: 8) {
            Label(widget.title, systemImage: widget.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            widget.makeSummary?()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(isHovering ? 0.12 : 0.08), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open \(widget.title)", open)
        .help("Open \(widget.title)")
    }
}

private struct HomeSettings: View {
    @AppStorage(PreferenceKey.widgetPreferences) private var storedWidgetPreferences = ""
    @AppStorage(hiddenSummaryIDsKey) private var storedHiddenIDs = ""
    @AppStorage(maxColumnsKey) private var maxColumns = defaultMaxColumns

    var body: some View {
        Form {
            Picker("Cards per row", selection: $maxColumns) {
                ForEach(1...3, id: \.self) { Text("\($0)").tag($0) }
            }
            Section("Summaries") {
                Text("Home shows them in the order set in Settings → Widgets. Click a card to open its widget.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(NotchWidget.getPreferences(stored: storedWidgetPreferences)) { preference in
                    if let widget = NotchWidget.find(id: preference.id), widget.makeSummary != nil {
                        Toggle(isOn: makeVisibilityBinding(for: widget.id)) {
                            Label(widget.title, systemImage: widget.systemImage)
                        }
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
