import Foundation

public func getCityName(forTimeZoneIdentifier identifier: String) -> String {
    let city = identifier.split(separator: "/").last.map(String.init) ?? identifier
    return city.replacingOccurrences(of: "_", with: " ")
}

public func formatOffset(seconds: Int) -> String {
    let duration = Duration.seconds(abs(seconds)).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    return (seconds < 0 ? "−" : "+") + duration
}

/// "Here" for the Mac's own zone, where "+0m" would read as a glitch; otherwise the offset from it.
public func formatOffsetLabel(seconds: Int, isLocal: Bool) -> String {
    isLocal ? String(localized: "Here", bundle: .module) : formatOffset(seconds: seconds)
}
