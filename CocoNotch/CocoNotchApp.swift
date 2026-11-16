import SwiftUI

@main
struct CocoNotchApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        MenuBarExtra("CocoNotch", systemImage: "rectangle.topthird.inset.filled") {
            MenuContent()
        }
        Settings {
            SettingsView()
        }
    }
}

private struct MenuContent: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            // A menu bar app is never frontmost, so without this the window opens behind other apps.
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit CocoNotch") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let panel = NotchPanel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        placePanel()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(placePanel),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func placePanel() {
        panel.placeOnNotchScreen()
    }
}
