import CocoNotchCore
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
    private var panels: [NotchPanel] = []
    private var placedDisplayChoice: NotchDisplayChoice?

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
        placePanels()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(placePanels),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // Fires for every settings write, possibly off the main thread, so hop to main and act only on a new choice.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.readDisplayChoice() != self.placedDisplayChoice else { return }
                self.placePanels()
            }
        }
    }

    func showSettings() {
        // A menu bar app is never frontmost, so without this the window opens behind other apps.
        NSApp.activate()
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    private func readDisplayChoice() -> NotchDisplayChoice {
        UserDefaults.standard.string(forKey: PreferenceKey.notchDisplay).flatMap { NotchDisplayChoice(rawValue: $0) }
            ?? .main
    }

    @objc private func placePanels() {
        let choice = readDisplayChoice()
        placedDisplayChoice = choice
        let screens = NSScreen.screens
        let indices = getNotchDisplayIndices(hasNotch: screens.map { $0.safeAreaInsets.top > 0 }, choice: choice)

        while panels.count < indices.count {
            panels.append(NotchPanel(showSettings: { [weak self] in self?.showSettings() }))
        }
        while panels.count > indices.count {
            panels.removeLast().close()
        }
        for (panel, index) in zip(panels, indices) {
            panel.place(on: screens[index])
        }
    }
}
