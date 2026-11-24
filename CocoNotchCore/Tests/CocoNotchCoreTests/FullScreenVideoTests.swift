import CocoNotchCore
import CoreGraphics
import Testing

private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
private let fullScreen = CGRect(x: 0, y: 38, width: 1512, height: 944)
private let playerPID: Int32 = 10

/// A window owned by the player, and one assertion held by `holderPID`.
private struct Case: Sendable {
    var bounds = fullScreen
    var layer = 0
    var holderPID = playerPID
    var type = "PreventUserIdleDisplaySleep"
    var onBehalfOfPID: Int32?
}

@Test(
    arguments: [
        (Case(), true),
        // A MacBook's 32pt camera housing leaves a 33pt strip above the full-screen window.
        (Case(bounds: CGRect(x: 0, y: 39, width: 1512, height: 943)), true),
        // A helper process holds it for the browser.
        (Case(holderPID: 20, type: "NoDisplaySleepAssertion", onBehalfOfPID: playerPID), true),
        // Full screen, but nothing playing.
        (Case(type: "PreventUserIdleSystemSleep"), false),
        // Playing, but in a window that leaves the menu bar showing.
        (Case(bounds: CGRect(x: 0, y: 60, width: 1512, height: 922)), false),
        // Another app keeps the display awake.
        (Case(holderPID: 30), false),
        // Above normal windows, like a menu bar item's panel.
        (Case(layer: 25), false),
        // Full screen on another display.
        (Case(bounds: CGRect(x: 1512, y: 0, width: 1920, height: 1080)), false),
    ])
private func detectsFullScreenVideo(testCase: Case, expected: Bool) {
    let window: [String: Any] = [
        kCGWindowOwnerPID as String: playerPID, kCGWindowLayer as String: testCase.layer,
        kCGWindowBounds as String: testCase.bounds.dictionaryRepresentation,
    ]
    var assertion: [String: Any] = ["AssertType": testCase.type]
    assertion["AssertionOnBehalfOfPID"] = testCase.onBehalfOfPID
    #expect(
        isPlayingFullScreenVideo(
            on: screen, topInset: 38, windowList: [window], assertionsByPID: [testCase.holderPID: [assertion]])
            == expected)
}

@Test(
    arguments: [
        (CGPoint(x: 700, y: 982), true),
        (CGPoint(x: 10, y: 950), true),
        // Below the menu bar, over the video.
        (CGPoint(x: 700, y: 900), false),
        // At the top of the display to the right.
        (CGPoint(x: 1600, y: 982), false),
    ])
func detectsPointerInMenuBar(pointer: CGPoint, expected: Bool) {
    #expect(isPointerInMenuBar(pointer, screen: screen, menuBarHeight: 38) == expected)
}

@Test(
    arguments: [
        ([screen], false, false, false, true),
        // Another display plays the video.
        ([CGRect(x: 1512, y: 0, width: 1920, height: 1080)], false, false, false, false),
        ([screen], true, false, false, false),
        ([screen], false, true, false, false),
        ([screen], false, false, true, false),
    ] as [([CGRect], Bool, Bool, Bool, Bool)])
func hidesNotchForVideo(videoScreens: [CGRect], isExpanded: Bool, isHovering: Bool, isAlerting: Bool, expected: Bool) {
    #expect(
        isNotchHiddenForVideo(
            on: screen, videoScreens: videoScreens, isExpanded: isExpanded, isHovering: isHovering,
            isAlerting: isAlerting) == expected)
}
