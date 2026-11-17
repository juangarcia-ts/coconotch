import CocoNotchCore
import Foundation
import Testing

@Test func measuresCPUUsageBetweenSamples() {
    let first = CPUTicks(user: 100, system: 50, idle: 800, nice: 50)
    let second = CPUTicks(user: 160, system: 70, idle: 900, nice: 70)
    #expect(getCPUUsage(from: first, to: second) == 0.5)
    #expect(getCPUUsage(from: first, to: first) == nil)
    // A counter going back means the samples can't be compared.
    #expect(getCPUUsage(from: second, to: first) == nil)
}

@Test func countsMemoryUsedLikeActivityMonitor() {
    let pages = MemoryPages(internalPages: 1000, purgeable: 200, wired: 300, compressed: 100)
    #expect(getMemoryUsed(pages, pageSize: 16384) == 1200 * 16384)
    let allPurgeable = MemoryPages(internalPages: 10, purgeable: 20, wired: 5, compressed: 0)
    #expect(getMemoryUsed(allPurgeable, pageSize: 4096) == 5 * 4096)
}

@Test func parsesBattery() throws {
    let discharging = try #require(
        parseBattery([
            "Type": "InternalBattery", "Current Capacity": 42, "Max Capacity": 100, "Is Charging": false,
            "Time to Empty": 125, "Power Source State": "Battery Power",
        ]))
    #expect(discharging == BatteryStatus(percent: 42, isCharging: false, isOnPower: false, minutesRemaining: 125))
    let estimating = try #require(
        parseBattery([
            "Type": "InternalBattery", "Current Capacity": 80, "Max Capacity": 100, "Is Charging": true,
            "Time to Full Charge": -1, "Power Source State": "AC Power",
        ]))
    #expect(estimating.minutesRemaining == nil)
    #expect(estimating.isOnPower)
    #expect(parseBattery(["Type": "UPS", "Current Capacity": 80, "Max Capacity": 100]) == nil)
}

@Test func showsLowBatteryHeadsUpOnlyOffPowerAndWhenOn() {
    let low = BatteryStatus(percent: 15, isCharging: false, isOnPower: false, minutesRemaining: nil)
    #expect(shouldShowLowBatteryHeadsUp(low, isWidgetEnabled: true, isHeadsUpOn: true, threshold: 20))
    #expect(shouldShowLowBatteryHeadsUp(low, isWidgetEnabled: true, isHeadsUpOn: true, threshold: 15))
    #expect(!shouldShowLowBatteryHeadsUp(low, isWidgetEnabled: true, isHeadsUpOn: true, threshold: 10))
    #expect(!shouldShowLowBatteryHeadsUp(low, isWidgetEnabled: false, isHeadsUpOn: true, threshold: 20))
    #expect(!shouldShowLowBatteryHeadsUp(low, isWidgetEnabled: true, isHeadsUpOn: false, threshold: 20))
    #expect(!shouldShowLowBatteryHeadsUp(nil, isWidgetEnabled: true, isHeadsUpOn: true, threshold: 20))
    let pluggedIn = BatteryStatus(percent: 15, isCharging: true, isOnPower: true, minutesRemaining: nil)
    #expect(!shouldShowLowBatteryHeadsUp(pluggedIn, isWidgetEnabled: true, isHeadsUpOn: true, threshold: 20))
}

@Test func picksBatterySymbolByLevel() {
    func symbol(_ percent: Int, isCharging: Bool = false) -> String {
        getBatterySymbol(
            BatteryStatus(percent: percent, isCharging: isCharging, isOnPower: isCharging, minutesRemaining: nil))
    }
    #expect(symbol(12) == "battery.0percent")
    #expect(symbol(13) == "battery.25percent")
    #expect(symbol(37) == "battery.25percent")
    #expect(symbol(38) == "battery.50percent")
    #expect(symbol(62) == "battery.50percent")
    #expect(symbol(63) == "battery.75percent")
    #expect(symbol(87) == "battery.75percent")
    #expect(symbol(88) == "battery.100percent")
    #expect(symbol(5, isCharging: true) == "battery.100percent.bolt")
}

@Test func describesBatteryState() {
    func detail(isCharging: Bool, isOnPower: Bool, minutes: Int?) -> String {
        getBatteryDetail(
            BatteryStatus(percent: 50, isCharging: isCharging, isOnPower: isOnPower, minutesRemaining: minutes))
    }
    #expect(detail(isCharging: true, isOnPower: true, minutes: 45) == "0:45 until full")
    #expect(detail(isCharging: true, isOnPower: true, minutes: nil) == "Charging")
    #expect(detail(isCharging: false, isOnPower: true, minutes: nil) == "On power")
    #expect(detail(isCharging: false, isOnPower: false, minutes: 125) == "2:05 left")
    #expect(detail(isCharging: false, isOnPower: false, minutes: nil) == "On battery")
}

@Test func measuresDiskUsedFraction() {
    #expect(getDiskUsedFraction(free: 250, total: 1000) == 0.75)
    #expect(getDiskUsedFraction(free: 1200, total: 1000) == 0)
    #expect(getDiskUsedFraction(free: 0, total: 0) == 0)
}

@Test func formatsSystemValues() {
    let locale = Locale(identifier: "en_US")
    #expect(formatPercent(0.424) == "42%")
    #expect(formatPercent(1.2) == "100%")
    #expect(formatBytes(8 * 1024 * 1024 * 1024, isMemory: true, locale: locale) == "8 GB")
    #expect(formatBytes(250_000_000_000, isMemory: false, locale: locale) == "250 GB")
    #expect(formatTimeRemaining(minutes: 65) == "1:05")
    #expect(formatTimeRemaining(minutes: 600) == "10:00")
}

@Test func readsMemoryPressure() {
    #expect(parseMemoryPressure(level: 1) == .normal)
    #expect(parseMemoryPressure(level: 2) == .warning)
    #expect(parseMemoryPressure(level: 4) == .critical)
    #expect(parseMemoryPressure(level: 0) == nil)
    #expect(getMemoryPressureLabel(.warning) == "Warning")
    #expect(getMemoryPressureFraction(freePercent: 44) == 0.56)
    #expect(getMemoryPressureFraction(freePercent: 120) == 0)
}

@Test func keepsAMinuteOfHistory() {
    #expect(getHistoryLimit(sampleSeconds: 3, spanSeconds: 60) == 21)
    #expect(getHistoryLimit(sampleSeconds: 0, spanSeconds: 60) == 61)
    #expect(appendHistory([0.1, 0.2, 0.3], 0.4, limit: 3) == [0.2, 0.3, 0.4])
    #expect(appendHistory([], 0.5, limit: 3) == [0.5])
}
