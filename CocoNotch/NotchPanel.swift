import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
    // The most the expanded notch may take; NotchView clips taller content. Clicks on the transparent area fall
    // through to the menu bar.
    static let size = NSSize(width: 640, height: 300)

    private let showSettings: () -> Void
    private var placedScreenFrame: NSRect?
    private var placedNotchSize: CGSize?

    init(showSettings: @escaping () -> Void) {
        self.showSettings = showSettings
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
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

    func place(on screen: NSScreen) {
        // Keep the view, and whether it's open, when neither the screen nor its notch changed.
        guard screen.frame != placedScreenFrame || screen.notchSize != placedNotchSize else { return }
        placedScreenFrame = screen.frame
        placedNotchSize = screen.notchSize
        let hostingView = NSHostingView(rootView: NotchView(notchSize: screen.notchSize, showSettings: showSettings))
        hostingView.sizingOptions = []
        contentView = hostingView
        setFrame(
            NSRect(
                x: screen.frame.midX - Self.size.width / 2,
                y: screen.frame.maxY - Self.size.height,
                width: Self.size.width,
                height: Self.size.height
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
}
