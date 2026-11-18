import CocoNotchCore
import Foundation
import Testing

private func getZone(_ identifier: String) throws -> TimeZone {
    try #require(TimeZone(identifier: identifier))
}

// 2026-01-15 23:30 UTC.
private let lateEvening = Date(timeIntervalSince1970: 1_768_519_800)

@Test func readsTheLocalHourInAZone() throws {
    #expect(getLocalHour(at: lateEvening, in: try getZone("UTC")) == 23.5)
    #expect(getLocalHour(at: lateEvening, in: try getZone("Asia/Kolkata")) == 5)
}

@Test(arguments: [(3.0, 0.0), (7.0, 0.5), (12.0, 1.0), (19.0, 0.5), (22.0, 0.0), (31.0, 0.5), (-5.0, 0.5)])
func shadesTheHourFromNightToDay(hour: Double, daylight: Double) {
    #expect(getDaylight(hour: hour) == daylight)
}

@Test func callsDawnAndDuskByTheMiddleOfTheChange() {
    #expect(!isDaytime(hour: 6.5))
    #expect(isDaytime(hour: 7))
    #expect(!isDaytime(hour: 19.5))
}

@Test(arguments: [(18.0, 0.25), (0.0, 0.0), (23.5, 0.5 / 24)])
func placesMidnightOnTheTimeline(startHour: Double, fraction: Double) {
    #expect(getMidnightFraction(startHour: startHour) == fraction)
}

@Test(arguments: [(0.5, 0.0), (1.0, 12.0), (0.0, -12.0), (1.5, 12.0), (0.51, 0.25), (0.6, 2.5)])
func turnsADragIntoQuarterHours(fraction: Double, hours: Double) {
    #expect(getScrubHourOffset(fraction: fraction) == hours)
}

@Test func namesTheDayOnlyWhenItDiffers() throws {
    let utc = try getZone("UTC")
    #expect(formatRelativeDay(at: lateEvening, in: try getZone("Asia/Tokyo"), localZone: utc) == "Tomorrow")
    #expect(formatRelativeDay(at: lateEvening, in: utc, localZone: try getZone("Asia/Tokyo")) == "Yesterday")
    #expect(formatRelativeDay(at: lateEvening, in: try getZone("America/New_York"), localZone: utc) == nil)
}
