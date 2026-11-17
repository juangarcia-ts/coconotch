import CocoNotchCore
import ServiceManagement
import SwiftUI

private enum SettingsPage: Hashable {
    case general
    case appearance
    case shortcuts
    case widgets
    case widget(String)
}

struct SettingsView: View {
    static let size = CGSize(width: 760, height: 520)

    @AppStorage(PreferenceKey.widgetPreferences) private var storedWidgetPreferences = ""
    @State private var page = SettingsPage.general
    @State private var isWidgetsExpanded = true

    /// Home first, then every widget with settings in the user's order, switched on or not.
    private var widgetsWithSettings: [NotchWidget] {
        ([NotchWidget.home]
            + NotchWidget.getPreferences(stored: storedWidgetPreferences).compactMap {
                NotchWidget.find(id: $0.id)
            })
            .filter { $0.makeSettings != nil }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Label("General", systemImage: "gearshape")
                    .tag(SettingsPage.general)
                Label("Appearance", systemImage: "paintpalette")
                    .tag(SettingsPage.appearance)
                Label("Shortcuts", systemImage: "keyboard")
                    .tag(SettingsPage.shortcuts)
                DisclosureGroup(isExpanded: $isWidgetsExpanded) {
                    ForEach(widgetsWithSettings) { widget in
                        Label {
                            Text(widget.title)
                        } icon: {
                            WidgetIcon(widget: widget)
                        }
                        .tag(SettingsPage.widget(widget.id))
                    }
                } label: {
                    Label("Widgets", systemImage: "square.grid.2x2")
                        .tag(SettingsPage.widgets)
                }
            }
            // Wide enough for the longest widget name, "Time Zones", without truncating.
            .navigationSplitViewColumnWidth(230)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                Text(getTitle(of: page))
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        // Grouped forms have no natural height, so without a fixed size the window collapses.
        .frame(width: Self.size.width, height: Self.size.height)
    }

    @ViewBuilder private var detail: some View {
        switch page {
        case .general:
            GeneralSettings()
        case .appearance:
            AppearanceSettings()
        case .shortcuts:
            ShortcutsSettings()
        case .widgets:
            WidgetsSettings()
        case .widget(let id):
            NotchWidget.find(id: id)?.makeSettings?()
        }
    }

    private func getTitle(of page: SettingsPage) -> String {
        switch page {
        case .general: "General"
        case .appearance: "Appearance"
        case .shortcuts: "Shortcuts"
        case .widgets: "Widgets"
        case .widget(let id): NotchWidget.find(id: id)?.title ?? ""
        }
    }
}

private struct GeneralSettings: View {
    @AppStorage(PreferenceKey.expandsOnClick) private var expandsOnClick = false
    @AppStorage(PreferenceKey.notchDisplay) private var notchDisplay = NotchDisplayChoice.main
    @AppStorage(PreferenceKey.showsActivities) private var showsActivities = true
    @State private var launchAtLoginStatus = SMAppService.mainApp.status
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Picker("Open the notch", selection: $expandsOnClick) {
                Text("On hover").tag(false)
                Text("On click").tag(true)
            }
            Picker("Show the notch on", selection: $notchDisplay) {
                Text("Main display").tag(NotchDisplayChoice.main)
                Text("Built-in display").tag(NotchDisplayChoice.builtIn)
                Text("All displays").tag(NotchDisplayChoice.all)
            }
            Toggle("Show live activities in the closed notch", isOn: $showsActivities)
            Toggle(
                "Launch at login",
                // Pending approval counts as on, so the user can still switch it off and withdraw the request.
                isOn: Binding(
                    get: { [.enabled, .requiresApproval].contains(launchAtLoginStatus) },
                    // A closure, not `set: setLaunchAtLogin`: passing the method crashes the Swift 6.3 compiler.
                    set: { setLaunchAtLogin($0) }
                )
            )
            if launchAtLoginStatus == .requiresApproval {
                Text("Allow CocoNotch in System Settings → General → Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        // The user may approve or remove CocoNotch in System Settings while this window stays open.
        .onAppear { launchAtLoginStatus = SMAppService.mainApp.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLoginStatus = SMAppService.mainApp.status
        }
    }

    private func setLaunchAtLogin(_ isEnabled: Bool) {
        do {
            if isEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLoginStatus = SMAppService.mainApp.status
    }
}

private struct AppearanceSettings: View {
    @AppStorage(PreferenceKey.backgroundStyle) private var backgroundStyle = BackgroundStyle.solid
    @AppStorage(PreferenceKey.backgroundColor) private var backgroundColorData = Data()
    @AppStorage(PreferenceKey.backgroundOpacity) private var backgroundOpacity = 1.0
    @AppStorage(PreferenceKey.notchScale) private var notchScale = 1.0
    @Environment(\.self) private var environment

    var body: some View {
        Form {
            Picker("Background", selection: $backgroundStyle) {
                Text("Solid color").tag(BackgroundStyle.solid)
                Text("Blur").tag(BackgroundStyle.blur)
            }
            if backgroundStyle == .solid {
                ColorPicker(
                    "Color",
                    selection: Binding(
                        get: { Color(colorData: backgroundColorData) },
                        set: { backgroundColorData = $0.encodeColorData(in: environment) }
                    ),
                    supportsOpacity: false
                )
            }
            // Below 30% the white text stops being readable on most wallpapers.
            Slider(value: $backgroundOpacity, in: 0.3...1) { Text("Opacity") }
            LabeledContent("Size") {
                HStack {
                    Slider(value: $notchScale, in: notchScaleRange, step: 0.1) { Text("Size") }
                        .labelsHidden()
                    Text(notchScale.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            Text("The closed notch always stays black so it blends with the screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct WidgetsSettings: View {
    @AppStorage(PreferenceKey.widgetPreferences) private var storedWidgetPreferences = ""
    @AppStorage(PreferenceKey.preferredActivityWidget) private var preferredActivityWidgetID = ""
    @AppStorage(PreferenceKey.showsHome) private var showsHome = true
    // Edited locally and saved on every change, so dragging doesn't decode the stored list on each frame.
    @State private var preferences: [WidgetPreference] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Preferred activity", selection: $preferredActivityWidgetID) {
                Text("Automatic").tag("")
                ForEach(NotchWidget.all) { widget in
                    Text(widget.title).tag(widget.id)
                }
            }
            Text("The closed notch shows this widget's activity first. Automatic picks the most urgent one.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Text("Drag to reorder. The notch shows the widgets that are on, in this order.")
                .font(.caption)
                .foregroundStyle(.secondary)
            List {
                HStack {
                    DragHandle()
                        .hidden()
                    Label(NotchWidget.home.title, systemImage: NotchWidget.home.systemImage)
                    Text("Always first")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Show \(NotchWidget.home.title)", isOn: $showsHome)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                ForEach($preferences) { $preference in
                    if let widget = NotchWidget.find(id: preference.id) {
                        HStack {
                            DragHandle()
                            Label {
                                Text(widget.title)
                            } icon: {
                                WidgetIcon(widget: widget)
                            }
                            Spacer()
                            Toggle("Show \(widget.title)", isOn: $preference.isEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .disabled(!canToggleWidget(preference.id, in: preferences))
                        }
                    }
                }
                .onMove { preferences.move(fromOffsets: $0, toOffset: $1) }
            }
        }
        .padding(20)
        .onAppear { preferences = NotchWidget.getPreferences(stored: storedWidgetPreferences) }
        .onChange(of: preferences) { storedWidgetPreferences = encodeWidgetPreferences(preferences) }
    }
}

/// macOS only starts a row drag from a spot that isn't a control, so rows full of controls get this as a grip.
struct DragHandle: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .foregroundStyle(.tertiary)
            .frame(width: 20, height: 24)
            .contentShape(Rectangle())
            .help("Drag to reorder")
    }
}

private struct ShortcutsSettings: View {
    @AppStorage(PreferenceKey.widgetShortcuts) private var widgetShortcuts = WidgetShortcutsMode.visible
    @AppStorage(PreferenceKey.widgetPreferences) private var storedWidgetPreferences = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Open or close the notch") {
                    HotKeyRecorder(storageKey: openNotchHotKeyKey)
                }
            } footer: {
                Text("Works in any app. A shortcut another app already uses won't work here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Widget tabs in the open notch") {
                Picker("⌘1…⌘0, then ⌥⌘1…⌥⌘0", selection: $widgetShortcuts) {
                    Text("Visible").tag(WidgetShortcutsMode.visible)
                    Text("Hidden").tag(WidgetShortcutsMode.hidden)
                    Text("Disabled").tag(WidgetShortcutsMode.disabled)
                }
            }
            Section("Open a widget from any app") {
                ForEach(
                    [NotchWidget.home]
                        + NotchWidget.getPreferences(stored: storedWidgetPreferences).compactMap {
                            NotchWidget.find(id: $0.id)
                        }
                ) { widget in
                    LabeledContent {
                        HotKeyRecorder(storageKey: getWidgetHotKeyKey(widgetID: widget.id))
                    } label: {
                        Label {
                            Text(widget.title)
                        } icon: {
                            WidgetIcon(widget: widget)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
