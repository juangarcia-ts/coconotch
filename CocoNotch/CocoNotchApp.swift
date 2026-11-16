import SwiftUI

@main
struct CocoNotchApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        MenuBarExtra("CocoNotch", systemImage: "rectangle.topthird.inset.filled") {
            ForEach(NotchWidget.all) { widget in
                if let makeMenuItems = widget.makeMenuItems {
                    Menu(widget.title) { makeMenuItems() }
                }
            }
            Divider()
            Button("Quit CocoNotch") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
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
