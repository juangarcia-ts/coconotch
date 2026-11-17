import Foundation

/// CPU time summed over every core, in scheduler ticks since boot.
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// The busy share of CPU time between two samples, from 0 to 1; nil when no time passed or the counters went back.
public func getCPUUsage(from previous: CPUTicks, to current: CPUTicks) -> Double? {
    guard current.user >= previous.user, current.system >= previous.system, current.idle >= previous.idle,
        current.nice >= previous.nice
    else { return nil }
    let busy = (current.user - previous.user) + (current.system - previous.system) + (current.nice - previous.nice)
    let total = busy + (current.idle - previous.idle)
    return total == 0 ? nil : Double(busy) / Double(total)
}

/// The page counts from `vm_statistics64` that make up memory in use.
public struct MemoryPages: Equatable, Sendable {
    public let internalPages: UInt64
    public let purgeable: UInt64
    public let wired: UInt64
    public let compressed: UInt64

    public init(internalPages: UInt64, purgeable: UInt64, wired: UInt64, compressed: UInt64) {
        self.internalPages = internalPages
        self.purgeable = purgeable
        self.wired = wired
        self.compressed = compressed
    }
}

/// Bytes in use the way Activity Monitor counts them: app memory (minus purgeable), wired and compressed.
public func getMemoryUsed(_ pages: MemoryPages, pageSize: UInt64) -> UInt64 {
    let appPages = pages.internalPages > pages.purgeable ? pages.internalPages - pages.purgeable : 0
    return (appPages + pages.wired + pages.compressed) * pageSize
}

public struct BatteryStatus: Equatable, Sendable {
    /// 0 to 100.
    public let percent: Int
    public let isCharging: Bool
    public let isOnPower: Bool
    /// Minutes until empty when on battery, or until full when charging; nil while macOS is still estimating.
    public let minutesRemaining: Int?

    public init(percent: Int, isCharging: Bool, isOnPower: Bool, minutesRemaining: Int?) {
        self.percent = percent
        self.isCharging = isCharging
        self.isOnPower = isOnPower
        self.minutesRemaining = minutesRemaining
    }
}

/// Reads an IOKit power source description; nil for anything but the internal battery.
public func parseBattery(_ description: [String: Any]) -> BatteryStatus? {
    guard description["Type"] as? String == "InternalBattery",
        let current = description["Current Capacity"] as? Int,
        let max = description["Max Capacity"] as? Int, max > 0
    else { return nil }
    let isCharging = description["Is Charging"] as? Bool ?? false
    let minutes = description[isCharging ? "Time to Full Charge" : "Time to Empty"] as? Int
    return BatteryStatus(
        percent: min(100, current * 100 / max),
        isCharging: isCharging,
        isOnPower: description["Power Source State"] as? String == "AC Power",
        minutesRemaining: minutes.flatMap { $0 > 0 ? $0 : nil }
    )
}

/// The closed-notch heads-up shows only off power, at or below the threshold, while the widget and the setting are on.
public func shouldShowLowBatteryHeadsUp(
    _ battery: BatteryStatus?, isWidgetEnabled: Bool, isHeadsUpOn: Bool, threshold: Int
) -> Bool {
    guard isWidgetEnabled, isHeadsUpOn, let battery else { return false }
    return !battery.isOnPower && battery.percent <= threshold
}

public func getBatterySymbol(_ battery: BatteryStatus) -> String {
    if battery.isCharging { return "battery.100percent.bolt" }
    return switch battery.percent {
    case ..<13: "battery.0percent"
    case ..<38: "battery.25percent"
    case ..<63: "battery.50percent"
    case ..<88: "battery.75percent"
    default: "battery.100percent"
    }
}

/// "1:05 left", "Charging", "On power"…, for under the battery level.
public func getBatteryDetail(_ battery: BatteryStatus) -> String {
    let time = battery.minutesRemaining.map { formatTimeRemaining(minutes: $0) }
    if battery.isCharging { return time.map { "\($0) until full" } ?? "Charging" }
    if battery.isOnPower { return "On power" }
    return time.map { "\($0) left" } ?? "On battery"
}

/// The share of a disk in use, from 0 to 1; 0 for a disk that reports no size.
public func getDiskUsedFraction(free: UInt64, total: UInt64) -> Double {
    guard total > 0 else { return 0 }
    return Double(total - min(free, total)) / Double(total)
}

/// The Disk tile's value and the line under it: the share in use, or the free space.
public func formatDisk(free: UInt64, total: UInt64, isPercent: Bool, locale: Locale = .current) -> (
    value: String, detail: String
) {
    let totalText = formatBytes(total, isMemory: false, locale: locale)
    let freeText = formatBytes(free, isMemory: false, locale: locale)
    return isPercent
        ? (formatPercent(getDiskUsedFraction(free: free, total: total)), "\(freeText) free of \(totalText)")
        : (freeText, "free of \(totalText)")
}

/// The Memory tile's value and the line under it: the pressure as a percent, or the amount in use.
public func formatMemory(
    used: UInt64?, total: UInt64, pressureFraction: Double?, isPercent: Bool, locale: Locale = .current
) -> (value: String, detail: String) {
    let totalText = formatBytes(total, isMemory: true, locale: locale)
    let usedText = used.map { formatBytes($0, isMemory: true, locale: locale) }
    if isPercent {
        return (pressureFraction.map(formatPercent) ?? "–", usedText.map { "\($0) of \(totalText)" } ?? totalText)
    }
    return (usedText ?? "–", "of \(totalText)")
}

public func formatPercent(_ fraction: Double) -> String {
    "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
}

/// Memory uses binary units like Activity Monitor; disks use decimal ones like Finder.
public func formatBytes(_ bytes: UInt64, isMemory: Bool, locale: Locale = .current) -> String {
    Int64(clamping: bytes).formatted(.byteCount(style: isMemory ? .memory : .file).locale(locale))
}

/// "1:05", like the battery menu.
public func formatTimeRemaining(minutes: Int) -> String {
    "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
}

public enum MemoryPressure: Equatable, Sendable {
    case normal, warning, critical
}

/// Reads `kern.memorystatus_vm_pressure_level`, the level Activity Monitor colors its pressure graph by.
public func parseMemoryPressure(level: Int32) -> MemoryPressure? {
    switch level {
    case 1: .normal
    case 2: .warning
    case 4: .critical
    default: nil
    }
}

public func getMemoryPressureLabel(_ pressure: MemoryPressure) -> String {
    switch pressure {
    case .normal: "Normal"
    case .warning: "Warning"
    case .critical: "Critical"
    }
}

/// How full memory is from the kernel's view, from `kern.memorystatus_level` (the percent it can still hand out).
public func getMemoryPressureFraction(freePercent: Int32) -> Double {
    1 - Double(min(max(freePercent, 0), 100)) / 100
}

/// How many samples cover `spanSeconds`, plus the one at the start.
public func getHistoryLimit(sampleSeconds: Int, spanSeconds: Int) -> Int {
    max(spanSeconds / max(sampleSeconds, 1), 1) + 1
}

/// Adds the newest sample, dropping the oldest past `limit`.
public func appendHistory(_ history: [Double], _ value: Double, limit: Int) -> [Double] {
    Array((history + [value]).suffix(limit))
}
