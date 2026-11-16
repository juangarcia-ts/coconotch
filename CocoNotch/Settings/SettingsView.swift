import CocoNotchCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(PreferenceKey.widgetPreferences) private var storedWidgetPreferences = ""

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            WidgetsSettings()
                .tabItem { Label("Widgets", systemImage: "square.grid.2x2") }
            HomeSettings()
                .tabItem { Label(NotchWidget.home.title, systemImage: NotchWidget.home.systemImage) }
            ForEach(NotchWidget.getPreferences(stored: storedWidgetPreferences)) { preference in
                if let widget = NotchWidget.find(id: preference.id), let makeSettings = widget.makeSettings {
                    makeSettings()
                        .tabItem { Label(widget.title, systemImage: widget.systemImage) }
                }
            }
        }
        // Grouped forms have no natural height, so without a fixed size the window collapses to the tab bar.
        .frame(width: 480, height: 480)
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
                            Label(widget.title, systemImage: widget.systemImage)
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
