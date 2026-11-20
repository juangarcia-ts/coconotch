import AppKit
import CocoNotchCore
import IOKit.pwr_mgt

/// The screens hiding the notch for a full-screen video, re-read once a second as nothing announces playback starting or
/// stopping.
@Observable
final class FullScreenVideoStore {
    static let shared = FullScreenVideoStore()

    private(set) var screenFrames: [NSRect] = []
    @ObservationIgnored private var videoScreens: [NSScreen] = []
    @ObservationIgnored private var pollingTask: Task<Void, Never>?

    func start() {
        guard pollingTask == nil else { return }
        // The menu bar slides down when the pointer reaches the top, and the notch comes back with it.
        _ = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in
            MainActor.assumeIsolated { FullScreenVideoStore.shared.updateScreenFrames() }
        }
        pollingTask = Task {
            while !Task.isCancelled {
                let isEnabled =
                    UserDefaults.standard.object(forKey: PreferenceKey.hidesForFullScreenVideo) as? Bool ?? true
                videoScreens = isEnabled ? readVideoScreens() : []
                updateScreenFrames()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func updateScreenFrames() {
        let pointer = NSEvent.mouseLocation
        let frames = videoScreens.filter {
            !isPointerInMenuBar(pointer, screen: $0.frame, menuBarHeight: $0.notchSize.height)
        }.map(\.frame)
        if frames != screenFrames { screenFrames = frames }
    }
}

private func readVideoScreens() -> [NSScreen] {
    guard let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
    let windowList =
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        ?? []
    var assertions: Unmanaged<CFDictionary>?
    _ = IOPMCopyAssertionsByProcess(&assertions)
    let assertionsByPID = (assertions?.takeRetainedValue() as? [NSNumber: [[String: Any]]] ?? [:])
        .reduce(into: [:]) { $0[$1.key.int32Value] = $1.value }
    return NSScreen.screens.filter { screen in
        // Window bounds count down from the top of the main display; screen frames count up from its bottom.
        let frame = screen.frame
        return isPlayingFullScreenVideo(
            on: CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height),
            topInset: screen.cameraHousingHeight, windowList: windowList, assertionsByPID: assertionsByPID)
    }
}
