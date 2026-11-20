import CoreGraphics
import Foundation

private let displaySleepAssertionTypes: Set = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]

/// Whether an app with a full-screen window on `screen` keeps the display awake, as video players do while playing.
/// `windowList` is `CGWindowListCopyWindowInfo` output and `assertionsByPID` is `IOPMCopyAssertionsByProcess` output;
/// `screen` is in the same top-left coordinates, and `topInset` is the strip a full-screen window leaves for the
/// camera housing.
public func isPlayingFullScreenVideo(
    on screen: CGRect, topInset: CGFloat, windowList: [[String: Any]], assertionsByPID: [Int32: [[String: Any]]]
) -> Bool {
    // Browsers may hold the assertion from a helper process on behalf of the app that owns the window.
    let awakePIDs = Set(
        assertionsByPID.flatMap { pid, assertions in
            assertions.filter { displaySleepAssertionTypes.contains($0["AssertType"] as? String ?? "") }
                .flatMap { [pid, $0["AssertionOnBehalfOfPID"] as? Int32].compactMap(\.self) }
        })
    // ponytail: a zoomed window with the Dock hidden also matches; hovering still opens the notch, so it's left be.
    return windowList.contains { window in
        guard window[kCGWindowLayer as String] as? Int == 0,
            let pid = window[kCGWindowOwnerPID as String] as? Int32, awakePIDs.contains(pid),
            let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
        else { return false }
        return bounds.minX == screen.minX && bounds.width == screen.width && bounds.maxY == screen.maxY
            && bounds.minY <= screen.minY + topInset
    }
}

/// Whether the pointer is in the strip at the top of `screen` where a full-screen space slides the menu bar down. Both
/// are in AppKit's bottom-left coordinates.
public func isPointerInMenuBar(_ pointer: CGPoint, screen: CGRect, menuBarHeight: CGFloat) -> Bool {
    pointer.x >= screen.minX && pointer.x < screen.maxX && pointer.y >= screen.maxY - menuBarHeight
        && pointer.y <= screen.maxY
}

/// Whether the closed notch fades out on `screen`; opening it, hovering it or an alert brings it back.
public func isNotchHiddenForVideo(
    on screen: CGRect, videoScreens: [CGRect], isExpanded: Bool, isHovering: Bool, isAlerting: Bool
) -> Bool {
    videoScreens.contains(screen) && !isExpanded && !isHovering && !isAlerting
}
