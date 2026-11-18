import CocoNotchCore
import ServiceManagement
import Sparkle
import SwiftUI

enum SettingsPage: Hashable {
    case general
    case appearance
    case shortcuts
    case widgets
    case widget(String)
}

/// The page the Settings window shows, owned by the app so it can open Settings on a given page.
@Observable
final class SettingsNavigation {
    var page = SettingsPage.general
}

/// Closes the notch and shows Settings on a page, for example a widget's own tab; called like a function.
struct ShowSettingsAction {
    let action: (SettingsPage) -> Void

    func callAsFunction(_ page: SettingsPage) {
        action(page)
    }
}

extension EnvironmentValues {
    @Entry var showSettings = ShowSettingsAction { _ in }
}

struct SettingsView: View {
    static let size = CGSize(width: 760, height: 520)

    @AppStorage(PreferenceKey.widgetPreferences) private var storedWidgetPreferences = ""
    @Bindable var navigation: SettingsNavigation
    let updater: SPUUpdater
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
            List(selection: $navigation.page) {
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
            // Wide enough for the longest names, "Appearance" and the indented "Time Zones", without truncating.
            .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 220)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                Text(getTitle(of: navigation.page))
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .toolbar(removing: .sidebarToggle)
        .modifier(HidesWindowTitle())
        // Grouped forms have no natural height, so without a fixed size the window collapses.
        .frame(width: Self.size.width, height: Self.size.height)
    }

    @ViewBuilder private var detail: some View {
        switch navigation.page {
        case .general:
            GeneralSettings(updater: updater)
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
    let updater: SPUUpdater
    @AppStorage(PreferenceKey.expandsOnClick) private var expandsOnClick = false
    @AppStorage(PreferenceKey.notchDisplay) private var notchDisplay = NotchDisplayChoice.main
    @AppStorage(PreferenceKey.showsActivities) private var showsActivities = true
    @State private var launchAtLoginStatus = SMAppService.mainApp.status
    @State private var launchAtLoginError: String?
    @State private var checksForUpdates = false
    @State private var isConfirmingReset = false
    @State private var resetError: String?

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
            // Sparkle owns this value, so mirror it rather than writing its defaults key behind its back.
            Toggle("Automatically check for updates", isOn: $checksForUpdates)
                .onChange(of: checksForUpdates) { updater.automaticallyChecksForUpdates = checksForUpdates }
            Section {
                Button("Reset to Defaults…", role: .destructive) { isConfirmingReset = true }
                if let resetError {
                    Text(resetError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("Privacy permissions stay as they are; change them in System Settings → Privacy & Security.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset CocoNotch to defaults?", isPresented: $isConfirmingReset) {
            Button("Reset and Relaunch", role: .destructive) { resetToDefaults() }
        } message: {
            Text(
                "This deletes all settings, shelf files, clipboard history and Ask chats, "
                    + "and turns off launch at login.")
        }
        // The user may approve or remove CocoNotch in System Settings while this window stays open.
        .onAppear {
            launchAtLoginStatus = SMAppService.mainApp.status
            checksForUpdates = updater.automaticallyChecksForUpdates
        }
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

    private func resetToDefaults() {
        // Any exit that keeps Settings open must show whether login launch is still on.
        defer { launchAtLoginStatus = SMAppService.mainApp.status }
        // Stops before settings are cleared, so a failed step can be retried from the same button.
        do {
            if [.enabled, .requiresApproval].contains(SMAppService.mainApp.status) {
                try SMAppService.mainApp.unregister()
            }
            do {
                try FileManager.default.removeItem(at: URL.applicationSupportDirectory.appending(path: "CocoNotch"))
            } catch CocoaError.fileNoSuchFile {}
        } catch {
            resetError = "The reset stopped: \(error.localizedDescription)"
            return
        }
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        // Relaunching drops every store already loaded in memory; waiting for this process keeps `open` from reusing it.
        let relaunch = Process()
        relaunch.executableURL = URL(filePath: "/bin/sh")
        relaunch.arguments = [
            "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; open \"$0\"",
            Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier),
        ]
        do {
            try relaunch.run()
        } catch {
            resetError = "CocoNotch was reset but couldn't reopen itself. Quit it and open it again."
            return
        }
        NSApp.terminate(nil)
    }
}

private struct AppearanceSettings: View {
    @AppStorage(PreferenceKey.backgroundStyle) private var backgroundStyle = BackgroundStyle.blur
    @AppStorage(PreferenceKey.backgroundColor) private var backgroundColorData = Data()
    @AppStorage(PreferenceKey.backgroundOpacity) private var backgroundOpacity = 0.85
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

/// The page title is the heading; the window's own title would sit off its edge in the toolbar.
private struct HidesWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

private struct ShortcutsSettings: View {
    @AppStorage(PreferenceKey.widgetShortcuts) private var widgetShortcuts = WidgetShortcutsMode.visible
    @AppStorage(PreferenceKey.widgetPreferences) private var storedWidgetPreferences = ""
    @AppStorage(PreferenceKey.showsHome) private var showsHome = true

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
            Section {
                // The same tabs HotKeyCenter registers, so a switched-off widget can't get a shortcut that never fires.
                ForEach(
                    getTabIDs(
                        enabledIDs: getEnabledWidgetIDs(NotchWidget.getPreferences(stored: storedWidgetPreferences)),
                        showsHome: showsHome
                    ).compactMap { NotchWidget.find(id: $0) }
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
            } header: {
                Text("Open a widget from any app")
            } footer: {
                Text(
                    "Switched-off widgets aren't listed. A shortcut you recorded comes back when you switch its widget on."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
