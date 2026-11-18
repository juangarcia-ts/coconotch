import Foundation

/// The hours a timeline shows on each side of now; dragging it moves time by up to this much.
public let timelineHalfSpan = 12.0

/// The local time of day in a zone, in hours from midnight, such as 18.5 for 6:30 PM.
public func getLocalHour(at date: Date, in zone: TimeZone) -> Double {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let components = calendar.dateComponents([.hour, .minute], from: date)
    return Double(components.hour ?? 0) + Double(components.minute ?? 0) / 60
}

/// How light it is at a local hour: 0 at night, 1 by day, rising from 6 to 8 and falling from 18 to 20.
public func getDaylight(hour: Double) -> Double {
    let hour = hour.truncatingRemainder(dividingBy: 24) + (hour < 0 ? 24 : 0)
    switch hour {
    case 6..<8: return (hour - 6) / 2
    case 8..<18: return 1
    case 18..<20: return (20 - hour) / 2
    default: return 0
    }
}

public func isDaytime(hour: Double) -> Bool {
    getDaylight(hour: hour) >= 0.5
}

/// Where the zone's midnight falls between `start` and `end`, from 0 to 1, or nil if none does. Measured in elapsed time,
/// so it stays right on days when the clocks change.
public func getMidnightFraction(from start: Date, to end: Date, in zone: TimeZone) -> Double? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let midnight = calendar.startOfDay(for: end)
    guard midnight > start, end > start else { return nil }
    return midnight.timeIntervalSince(start) / end.timeIntervalSince(start)
}

/// The hours a drag at `fraction` of the timeline's width moves time by, in quarter hours.
public func getScrubHourOffset(fraction: Double) -> Double {
    let hours = (min(max(fraction, 0), 1) - 0.5) * 2 * timelineHalfSpan
    return (hours * 4).rounded() / 4
}

/// "Tomorrow" or "Yesterday" when a zone's date is a day off the local one, its weekday when it's further, nil on the
/// same day.
public func formatRelativeDay(at date: Date, in zone: TimeZone, localZone: TimeZone) -> String? {
    func getDay(_ zone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.dateComponents([.year, .month, .day], from: date)
    }
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = .gmt
    guard let day = utc.date(from: getDay(zone)), let localDay = utc.date(from: getDay(localZone)) else { return nil }
    switch utc.dateComponents([.day], from: localDay, to: day).day ?? 0 {
    case 0: return nil
    case 1: return String(localized: "Tomorrow", bundle: .module)
    case -1: return String(localized: "Yesterday", bundle: .module)
    default: return date.formatted(Date.FormatStyle(timeZone: zone).weekday(.wide))
    }
}
