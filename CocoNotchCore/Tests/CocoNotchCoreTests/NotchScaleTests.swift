import CocoNotchCore
import Testing

@Test(
    arguments: [
        (nil, 1.0), (0, 1.0), (-2, 1.0), (.nan, 1.0), (.infinity, 1.0),
        (0.5, 0.8), (1.2, 1.2), (3, 1.6),
    ] as [(Double?, Double)])
func clampsNotchScale(stored: Double?, expected: Double) {
    #expect(clampNotchScale(stored) == expected)
}
