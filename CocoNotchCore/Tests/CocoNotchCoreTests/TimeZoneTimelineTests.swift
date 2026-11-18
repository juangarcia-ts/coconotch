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

@Test func placesMidnightOnTheTimeline() throws {
    let start = Date(timeIntervalSince1970: 1_768_500_000)  // 2026-01-15 18:00 UTC
    let fractions = getMidnightFractions(from: start, to: start.addingTimeInterval(24 * 3600), in: try getZone("UTC"))
    #expect(fractions == [0.25])
}

@Test func placesMidnightByElapsedTimeWhenTheClocksChange() throws {
    // 2026-03-08 06:00 UTC is 01:00 EST in New York, an hour before the clocks spring forward.
    let start = Date(timeIntervalSince1970: 1_772_949_600)
    let fractions = getMidnightFractions(
        from: start, to: start.addingTimeInterval(24 * 3600), in: try getZone("America/New_York"))
    let expected: [Double] = [22.0 / 24]
    #expect(fractions == expected)
}

@Test func marksBothMidnightsAroundA23HourDay() throws {
    let start = Date(timeIntervalSince1970: 1_772_944_200)  // 2026-03-08 04:30 UTC, 23:30 EST on March 7
    let fractions = getMidnightFractions(
        from: start, to: start.addingTimeInterval(24 * 3600), in: try getZone("America/New_York"))
    let expected: [Double] = [0.5 / 24, 23.5 / 24]
    #expect(fractions == expected)
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

@Test func namesTheWeekdayWhenTheDatesAreTwoDaysApart() throws {
    let morning = Date(timeIntervalSince1970: 1_767_349_800)  // 2026-01-02 10:30 UTC
    let label = formatRelativeDay(
        at: morning, in: try getZone("Pacific/Kiritimati"), localZone: try getZone("Pacific/Pago_Pago"))
    #expect(label == morning.formatted(Date.FormatStyle(timeZone: try getZone("Pacific/Kiritimati")).weekday(.wide)))
    #expect(label != "Tomorrow")
}
