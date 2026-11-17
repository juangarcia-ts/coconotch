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

@Test func cameraHousingInsetCoversTheHousingAtAnyScale() {
    #expect(getCameraHousingInset(height: 32, notchScale: 0.8) == 40)
    #expect(getCameraHousingInset(height: 32, notchScale: 1.6) == 20)
    #expect(getCameraHousingInset(height: 0, notchScale: 1.2) == 0)
}

@Test func appliedScaleMakes100PercentSlightlyBigger() {
    #expect(getAppliedNotchScale(1) == 1.1)
    #expect(getAppliedNotchScale(nil) == 1.1)
    #expect(getAppliedNotchScale(2) == 1.6 * 1.1)
}
