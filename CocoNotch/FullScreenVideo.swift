import AppKit
import CocoNotchCore
import IOKit.pwr_mgt

/// The screens playing a full-screen video, re-read once a second as nothing announces playback starting or stopping.
@Observable
final class FullScreenVideoStore {
    static let shared = FullScreenVideoStore()

    private(set) var screenFrames: [NSRect] = []
    @ObservationIgnored private var pollingTask: Task<Void, Never>?

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task {
            while !Task.isCancelled {
                let isEnabled =
                    UserDefaults.standard.object(forKey: PreferenceKey.hidesForFullScreenVideo) as? Bool ?? true
                let frames = isEnabled ? readVideoScreenFrames() : []
                if frames != screenFrames { screenFrames = frames }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private func readVideoScreenFrames() -> [NSRect] {
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
    }.map(\.frame)
}
