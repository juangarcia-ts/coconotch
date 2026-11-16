import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            ForEach(NotchWidget.all) { widget in
                if let makeSettings = widget.makeSettings {
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
    @State private var launchAtLoginStatus = SMAppService.mainApp.status
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Picker("Open the notch", selection: $expandsOnClick) {
                Text("On hover").tag(false)
                Text("On click").tag(true)
            }
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
            Text("The closed notch always stays black so it blends with the screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
