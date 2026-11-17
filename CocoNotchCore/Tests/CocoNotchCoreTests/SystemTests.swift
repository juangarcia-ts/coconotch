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

@Test func flagsLowBatteryOnlyOffPower() {
    let low = BatteryStatus(percent: 15, isCharging: false, isOnPower: false, minutesRemaining: nil)
    #expect(isBatteryLow(low, threshold: 20))
    #expect(!isBatteryLow(low, threshold: 10))
    let pluggedIn = BatteryStatus(percent: 15, isCharging: true, isOnPower: true, minutesRemaining: nil)
    #expect(!isBatteryLow(pluggedIn, threshold: 20))
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
