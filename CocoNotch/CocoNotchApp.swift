import CocoNotchCore
import Sparkle
import SwiftUI

@main
struct CocoNotchApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        MenuBarExtra("CocoNotch", systemImage: "rectangle.topthird.inset.filled") {
            Button("Settings…") { appDelegate.showSettings() }
                .keyboardShortcut(",")
            Button("Check for Updates…") { appDelegate.updaterController.checkForUpdates(nil) }
            Divider()
            Button("Quit CocoNotch") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panels: [NotchPanel] = []
    private var placedSettings: PlacementSettings?
    private let settingsNavigation = SettingsNavigation()
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    // An AppKit window rather than a SwiftUI Settings scene, which the notch panel has no way to open.
    private lazy var settingsWindow: NSWindow = {
        let hostingController = NSHostingController(
            rootView: SettingsView(navigation: settingsNavigation, updater: updaterController.updater))
        // The window has a fixed size. Letting SwiftUI resize it to fit loops with the full-size content view's safe
        // area during layout, and AppKit aborts the app.
        hostingController.sizingOptions = []
        let window = NSWindow(contentViewController: hostingController)
        window.title = "CocoNotch Settings"
        // Lets the sidebar run up under the traffic lights, like System Settings.
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(SettingsView.size)
        window.center()
        return window
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MeetingsStore.shared.start()
        WeatherStore.shared.start()
        AIUsageStore.shared.start()
        MusicStore.shared.start()
        SystemStore.shared.start()
        ClipboardStore.shared.start()
        ShelfStore.shared.start()
        HotKeyCenter.shared.start()
        placePanels()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(placePanels),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // Fires for every settings write, possibly off the main thread, so hop to main and act only when the display
        // or size changed.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, PlacementSettings.read() != self.placedSettings else { return }
                self.placePanels()
            }
        }
    }

    /// Every open picks its page, so the menu bar and the gear always start on General.
    func showSettings(page: SettingsPage = .general) {
        settingsNavigation.page = page
        // A menu bar app is never frontmost, so without this the window opens behind other apps.
        NSApp.activate()
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    @objc private func placePanels() {
        let settings = PlacementSettings.read()
        placedSettings = settings
        let choice = settings.display
        let screens = NSScreen.screens
        let indices = getNotchDisplayIndices(hasNotch: screens.map { $0.safeAreaInsets.top > 0 }, choice: choice)

        while panels.count < indices.count {
            panels.append(NotchPanel(showSettings: { [weak self] in self?.showSettings(page: $0) }))
        }
        while panels.count > indices.count {
            panels.removeLast().close()
        }
        for (panel, index) in zip(panels, indices) {
            panel.place(on: screens[index], scale: settings.scale)
        }
    }
}

/// The settings that decide where the notch panels go and how big they are.
private struct PlacementSettings: Equatable {
    let display: NotchDisplayChoice
    let scale: Double

    static func read() -> PlacementSettings {
        let defaults = UserDefaults.standard
        return PlacementSettings(
            display: defaults.string(forKey: PreferenceKey.notchDisplay).flatMap { NotchDisplayChoice(rawValue: $0) }
                ?? .main,
            scale: clampNotchScale(defaults.object(forKey: PreferenceKey.notchScale) as? Double)
        )
    }
}
