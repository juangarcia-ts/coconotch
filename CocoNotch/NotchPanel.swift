import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
    // The most the expanded notch may take at 100% size; NotchView clips taller content. Clicks on the transparent
    // area fall through to the menu bar.
    static let baseSize = NSSize(width: 720, height: 400)

    private let showSettings: (SettingsPage) -> Void
    private var placedScreenFrame: NSRect?
    private var placedNotchSize: CGSize?
    private var placedScale: Double?

    init(showSettings: @escaping (SettingsPage) -> Void) {
        self.showSettings = showSettings
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.baseSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        level = .mainMenu + 3
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }

    /// Gives the keyboard back to the window the user was in. Activating the other app does nothing, as it never
    /// stopped being active, and `makeFirstResponder(nil)` leaves the panel key; deactivating resigns it.
    func returnKeyFocus() {
        guard isKeyWindow else { return }
        if NSApp.isActive, let mainWindow = NSApp.mainWindow {
            mainWindow.makeKey()
        } else {
            NSApp.deactivate()
        }
    }

    func place(on screen: NSScreen, scale: Double) {
        // Keep the view, and whether it's open, when neither the screen nor its notch changed.
        let isSameScreen = screen.frame == placedScreenFrame && screen.notchSize == placedNotchSize
        guard !isSameScreen || scale != placedScale else { return }
        if !isSameScreen {
            let hostingView = NSHostingView(
                rootView: NotchView(
                    notchSize: screen.notchSize, cameraHousingHeight: screen.cameraHousingHeight,
                    panelID: ObjectIdentifier(self), showSettings: showSettings)
            )
            hostingView.sizingOptions = []
            contentView = hostingView
        }
        placedScreenFrame = screen.frame
        placedNotchSize = screen.notchSize
        placedScale = scale
        // The camera housing doesn't scale, so its room is added on top of the scaled panel.
        let size = NSSize(
            width: Self.baseSize.width * scale, height: Self.baseSize.height * scale + screen.cameraHousingHeight)
        setFrame(
            NSRect(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.maxY - size.height,
                width: size.width,
                height: size.height
            ),
            display: true
        )
        orderFrontRegardless()
    }
}

extension NSScreen {
    var notchSize: CGSize {
        guard let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else {
            // No notch: draw a menu-bar-high pill instead.
            return CGSize(width: 200, height: max(frame.maxY - visibleFrame.maxY, 24))
        }
        return CGSize(width: frame.width - left.width - right.width, height: safeAreaInsets.top)
    }

    /// How far the physical camera housing reaches down from the top; 0 on a display without one.
    var cameraHousingHeight: CGFloat {
        auxiliaryTopLeftArea == nil ? 0 : safeAreaInsets.top
    }
}
