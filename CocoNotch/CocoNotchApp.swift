import SwiftUI

@main
struct CocoNotchApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        MenuBarExtra("CocoNotch", systemImage: "rectangle.topthird.inset.filled") {
            Button("Settings…", action: appDelegate.showSettings)
                .keyboardShortcut(",")
            Divider()
            Button("Quit CocoNotch") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var panel = NotchPanel(showSettings: { [weak self] in self?.showSettings() })

    // An AppKit window rather than a SwiftUI Settings scene, which the notch panel has no way to open.
    private lazy var settingsWindow: NSWindow = {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
        window.title = "CocoNotch Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        placePanel()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(placePanel),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func showSettings() {
        // A menu bar app is never frontmost, so without this the window opens behind other apps.
        NSApp.activate()
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    @objc private func placePanel() {
        panel.placeOnNotchScreen()
    }
}
