import CocoNotchCore
import Testing

@Test(
    arguments: [
        // An external monitor holds the menu bar; the MacBook's notched screen is second.
        ([false, true], NotchDisplayChoice.main, [0]),
        ([false, true], NotchDisplayChoice.builtIn, [1]),
        ([false, true], NotchDisplayChoice.all, [0, 1]),
        // Lid closed: no display has a notch.
        ([false, false], NotchDisplayChoice.builtIn, [0]),
        ([true], NotchDisplayChoice.main, [0]),
        ([], NotchDisplayChoice.all, []),
    ] as [([Bool], NotchDisplayChoice, [Int])])
func choosesNotchDisplays(hasNotch: [Bool], choice: NotchDisplayChoice, expected: [Int]) {
    #expect(getNotchDisplayIndices(hasNotch: hasNotch, choice: choice) == expected)
}
