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

/// Where local midnight falls on a timeline that starts at `startHour`, from 0 at its left edge to 1 at its right.
public func getMidnightFraction(startHour: Double) -> Double {
    (24 - startHour).truncatingRemainder(dividingBy: 24) / 24
}

/// The hours a drag at `fraction` of the timeline's width moves time by, in quarter hours.
public func getScrubHourOffset(fraction: Double) -> Double {
    let hours = (min(max(fraction, 0), 1) - 0.5) * 2 * timelineHalfSpan
    return (hours * 4).rounded() / 4
}

/// "Tomorrow" or "Yesterday" when a zone's date differs from the local one at that moment; nil on the same day.
public func formatRelativeDay(at date: Date, in zone: TimeZone, localZone: TimeZone) -> String? {
    func getDay(_ zone: TimeZone) -> [Int] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return [components.year ?? 0, components.month ?? 0, components.day ?? 0]
    }
    let day = getDay(zone)
    let localDay = getDay(localZone)
    if day == localDay { return nil }
    return day.lexicographicallyPrecedes(localDay)
        ? String(localized: "Yesterday", bundle: .module)
        : String(localized: "Tomorrow", bundle: .module)
}
