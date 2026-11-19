import Charts
import CocoNotchCore
import Darwin
import IOKit.ps
import SwiftUI

extension NotchWidget {
    static let system = NotchWidget(
        id: "system",
        title: String(localized: "System"),
        systemImage: "cpu",
        makeView: { AnyView(SystemView()) },
        makeSettings: { AnyView(SystemSettings()) },
        makeSummary: { AnyView(SystemSummary()) }
    )
}

private let showsCPUKey = "system.showsCPU"
private let showsMemoryKey = "system.showsMemory"
private let showsDiskKey = "system.showsDisk"
private let showsBatteryKey = "system.showsBattery"
private let showsMemoryPercentKey = "system.showsMemoryPercent"
private let showsDiskPercentKey = "system.showsDiskPercent"
private let sampleSecondsKey = "system.sampleSeconds"
private let showsGraphsKey = "system.showsGraphs"
private let showsLowBatteryHeadsUpKey = "system.showsLowBatteryHeadsUp"
private let lowBatteryThresholdKey = "system.lowBatteryThreshold"

private let defaultSampleSeconds = 3
private let defaultLowBatteryThreshold = 20
private let lowBatteryActivityID = "system.lowBattery"
private let graphSpanSeconds = 60

private func readSetting<Value>(_ key: String, default defaultValue: Value) -> Value {
    UserDefaults.standard.object(forKey: key) as? Value ?? defaultValue
}

private func readCPUTicks() -> CPUTicks? {
    var cpuCount: natural_t = 0
    var info: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0
    guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
        let info
    else { return nil }
    defer {
        vm_deallocate(
            mach_task_self_, vm_address_t(bitPattern: info),
            vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
    }
    var ticks = CPUTicks()
    for cpu in 0..<Int(cpuCount) {
        let base = cpu * Int(CPU_STATE_MAX)
        let read = { (state: Int32) in UInt64(UInt32(bitPattern: info[base + Int(state)])) }
        ticks.user += read(CPU_STATE_USER)
        ticks.system += read(CPU_STATE_SYSTEM)
        ticks.idle += read(CPU_STATE_IDLE)
        ticks.nice += read(CPU_STATE_NICE)
    }
    return ticks
}

private func readMemoryUsed() -> UInt64? {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    let pages = MemoryPages(
        internalPages: UInt64(stats.internal_page_count),
        purgeable: UInt64(stats.purgeable_count),
        wired: UInt64(stats.wire_count),
        compressed: UInt64(stats.compressor_page_count)
    )
    return getMemoryUsed(pages, pageSize: UInt64(getpagesize()))
}

private func readDisk() -> (free: UInt64, total: UInt64)? {
    guard
        let values = try? URL(filePath: "/").resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ]),
        let free = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity
    else { return nil }
    return (UInt64(clamping: free), UInt64(clamping: total))
}

private func readSysctl(_ name: String) -> Int32? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
}

/// nil on a Mac without a battery.
private func readBattery() -> BatteryStatus? {
    let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
    return sources.lazy.compactMap { source in
        (IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]).flatMap(parseBattery)
    }.first
}

/// Samples only while a System view is on screen; battery changes arrive from IOKit, so the heads-up needs no polling.
@Observable
final class SystemStore {
    static let shared = SystemStore()

    private(set) var cpuUsage: Double?
    private(set) var memoryUsed: UInt64?
    private(set) var memoryPressure: MemoryPressure?
    private(set) var memoryPressureFraction: Double?
    private(set) var cpuHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    let memoryTotal = ProcessInfo.processInfo.physicalMemory
    private(set) var disk: (free: UInt64, total: UInt64)?
    private(set) var battery: BatteryStatus?
    @ObservationIgnored private var lastTicks: CPUTicks?
    @ObservationIgnored private var sampledAt: Date?
    @ObservationIgnored private var viewerCount = 0
    @ObservationIgnored private var samplingTask: Task<Void, Never>?
    @ObservationIgnored private var batterySource: CFRunLoopSource?
    /// The heads-up's percent and when it first went up; unrelated settings writes then change nothing.
    @ObservationIgnored private var postedHeadsUp: (percent: Int, since: Date)?

    func start() {
        guard batterySource == nil else { return }
        battery = readBattery()
        // Desktop Macs have no battery, so nothing is ever posted.
        guard battery != nil else { return }
        batterySource = IOPSNotificationCreateRunLoopSource(
            { _ in
                MainActor.assumeIsolated { SystemStore.shared.updateBattery() }
            }, nil)?.takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), batterySource, .defaultMode)
        // Catches the widget being switched on or off, and the heads-up settings, wherever they change.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) {
            _ in
            MainActor.assumeIsolated { SystemStore.shared.updateLowBatteryHeadsUp() }
        }
        updateLowBatteryHeadsUp()
    }

    /// Called as a System view appears; one loop serves every visible view, so the rate stays the user's interval.
    func beginSampling() {
        viewerCount += 1
        guard viewerCount == 1 else { return }
        samplingTask = Task { await runSampling() }
    }

    func endSampling() {
        viewerCount = max(viewerCount - 1, 0)
        guard viewerCount == 0 else { return }
        samplingTask?.cancel()
        samplingTask = nil
    }

    private func runSampling() async {
        let sampleSeconds = readSetting(sampleSecondsKey, default: defaultSampleSeconds)
        // Switching between Home and the tab keeps the graphs; after a longer gap they would join unrelated stretches.
        var delay = Double(sampleSeconds)
        if isStale(updatedAt: sampledAt, now: .now, maxAge: Double(sampleSeconds * 2 + 1)) {
            lastTicks = nil
            cpuUsage = nil
            cpuHistory = []
            memoryHistory = []
            // A quick second sample, so CPU doesn't read "–" for a whole interval.
            delay = 0.25
        }
        while !Task.isCancelled {
            sample()
            try? await Task.sleep(for: .seconds(delay))
            delay = Double(readSetting(sampleSecondsKey, default: defaultSampleSeconds))
        }
    }

    private func sample() {
        if let ticks = readCPUTicks() {
            if let lastTicks, let usage = getCPUUsage(from: lastTicks, to: ticks) {
                cpuUsage = usage
                cpuHistory = appendHistory(cpuHistory, usage, limit: historyLimit)
            }
            lastTicks = ticks
        }
        memoryUsed = readMemoryUsed()
        memoryPressure = readSysctl("kern.memorystatus_vm_pressure_level").flatMap { parseMemoryPressure(level: $0) }
        memoryPressureFraction = readSysctl("kern.memorystatus_level").map {
            getMemoryPressureFraction(freePercent: $0)
        }
        if let memoryPressureFraction {
            memoryHistory = appendHistory(memoryHistory, memoryPressureFraction, limit: historyLimit)
        }
        sampledAt = .now
        disk = readDisk()
        battery = readBattery()
    }

    var historyLimit: Int {
        getHistoryLimit(
            sampleSeconds: readSetting(sampleSecondsKey, default: defaultSampleSeconds), spanSeconds: graphSpanSeconds)
    }

    private func updateBattery() {
        battery = readBattery()
        updateLowBatteryHeadsUp()
    }

    private func updateLowBatteryHeadsUp() {
        let preferences = NotchWidget.getPreferences(
            stored: UserDefaults.standard.string(forKey: PreferenceKey.widgetPreferences) ?? "")
        guard
            shouldShowLowBatteryHeadsUp(
                battery,
                isWidgetEnabled: getEnabledWidgetIDs(preferences).contains(NotchWidget.system.id),
                isHeadsUpOn: readSetting(showsLowBatteryHeadsUpKey, default: true),
                threshold: readSetting(lowBatteryThresholdKey, default: defaultLowBatteryThreshold)
            ), let battery
        else {
            if postedHeadsUp != nil { ActivityCenter.shared.remove(id: lowBatteryActivityID) }
            postedHeadsUp = nil
            return
        }
        guard postedHeadsUp?.percent != battery.percent else { return }
        let since = postedHeadsUp?.since ?? .now
        postedHeadsUp = (battery.percent, since)
        ActivityCenter.shared.post(
            NotchActivity(
                id: lowBatteryActivityID,
                widgetID: NotchWidget.system.id,
                priority: .normal,
                sortDate: since,
                makeLeading: {
                    AnyView(Label("Low battery", systemImage: "battery.25percent").foregroundStyle(.red))
                },
                makeTrailing: { AnyView(Text("\(battery.percent)%").monospacedDigit()) },
                makeCompact: {
                    AnyView(
                        Label("\(battery.percent)%", systemImage: "battery.25percent")
                            .foregroundStyle(.red)
                            .monospacedDigit()
                    )
                }
            )
        )
    }
}

private struct Metric: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let value: String
    let fraction: Double?
    let detail: String
    /// What the Home card shows when it differs from `value`.
    var shortValue: String? = nil
    /// The last minute, oldest first; empty means the metric has no graph.
    var history: [Double] = []
    /// Set when the color carries meaning, such as memory pressure.
    var tint: Color?
}

private func getPressureColor(_ pressure: MemoryPressure) -> Color {
    switch pressure {
    case .normal: .green
    case .warning: .yellow
    case .critical: .red
    }
}

/// The metrics the user switched on, in a fixed order, from the store's latest sample.
private func makeMetrics(
    _ store: SystemStore, showsCPU: Bool, showsMemory: Bool, showsDisk: Bool, showsBattery: Bool
) -> [Metric] {
    var metrics: [Metric] = []
    if showsCPU {
        metrics.append(
            Metric(
                id: "cpu", title: "CPU", symbol: "cpu", value: store.cpuUsage.map(formatPercent) ?? "–",
                fraction: store.cpuUsage,
                detail: String(localized: "\(ProcessInfo.processInfo.activeProcessorCount) cores"),
                history: store.cpuHistory))
    }
    if showsMemory {
        let text = formatMemory(
            used: store.memoryUsed, total: store.memoryTotal, pressureFraction: store.memoryPressureFraction,
            isPercent: readSetting(showsMemoryPercentKey, default: true))
        metrics.append(
            Metric(
                id: "memory", title: String(localized: "Memory"), symbol: "memorychip", value: text.value,
                fraction: store.memoryPressureFraction, detail: text.detail, history: store.memoryHistory,
                tint: store.memoryPressure.map(getPressureColor)))
    }
    if showsDisk, let disk = store.disk {
        let text = formatDisk(
            free: disk.free, total: disk.total, isPercent: readSetting(showsDiskPercentKey, default: true))
        metrics.append(
            Metric(
                id: "disk", title: String(localized: "Disk"), symbol: "internaldrive", value: text.value,
                fraction: getDiskUsedFraction(free: disk.free, total: disk.total), detail: text.detail))
    }
    if showsBattery, let battery = store.battery {
        metrics.append(
            Metric(
                id: "battery", title: String(localized: "Battery"), symbol: getBatterySymbol(battery),
                value: "\(battery.percent)%",
                fraction: Double(battery.percent) / 100, detail: getBatteryDetail(battery)))
    }
    return metrics
}

private struct SystemView: View {
    @AppStorage(showsCPUKey) private var showsCPU = true
    @AppStorage(showsMemoryKey) private var showsMemory = true
    @AppStorage(showsDiskKey) private var showsDisk = true
    @AppStorage(showsBatteryKey) private var showsBattery = true
    @AppStorage(showsGraphsKey) private var showsGraphs = true
    private let store = SystemStore.shared

    var body: some View {
        let metrics = makeMetrics(
            store, showsCPU: showsCPU, showsMemory: showsMemory, showsDisk: showsDisk, showsBattery: showsBattery)
        Group {
            if metrics.isEmpty {
                Text("Choose what System shows in Settings → System.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(metrics) { metric in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(metric.title, systemImage: metric.symbol)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(metric.value)
                                .font(.title2.weight(.semibold).monospacedDigit())
                                .lineLimit(1)
                            if showsGraphs, !metric.history.isEmpty {
                                Sparkline(
                                    values: metric.history, limit: store.historyLimit, tint: metric.tint ?? .accentColor
                                )
                            } else {
                                ProgressView(value: metric.fraction ?? 0)
                                    .progressViewStyle(.linear)
                                    .tint(metric.tint ?? .accentColor)
                            }
                            Text(metric.detail)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                // Lets every tile stretch to the tallest one, so a graph doesn't make its tile stand out.
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { store.beginSampling() }
        .onDisappear { store.endSampling() }
    }
}

/// The last minute as a filled line; new samples enter on the right, so a short history starts mid-way.
private struct Sparkline: View {
    let values: [Double]
    let limit: Int
    let tint: Color

    var body: some View {
        let offset = max(limit - values.count, 0)
        Chart(Array(values.enumerated()), id: \.offset) { index, value in
            AreaMark(x: .value("Time", offset + index), y: .value("Usage", value))
                .foregroundStyle(tint.opacity(0.25))
            LineMark(x: .value("Time", offset + index), y: .value("Usage", value))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartXScale(domain: 0...max(limit - 1, 1))
        .chartYScale(domain: 0...1)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 28)
    }
}

/// One row of icon and value per metric, for the Home tab; wraps to two rows in a half-width card.
private struct SystemSummary: View {
    @AppStorage(showsCPUKey) private var showsCPU = true
    @AppStorage(showsMemoryKey) private var showsMemory = true
    @AppStorage(showsDiskKey) private var showsDisk = true
    @AppStorage(showsBatteryKey) private var showsBattery = true
    private let store = SystemStore.shared

    var body: some View {
        let metrics = makeMetrics(
            store, showsCPU: showsCPU, showsMemory: showsMemory, showsDisk: showsDisk, showsBattery: showsBattery)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                ForEach(metrics, content: item)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                ForEach(makeRows(metrics, columnCount: 2).indices, id: \.self) { index in
                    GridRow {
                        ForEach(makeRows(metrics, columnCount: 2)[index], content: item)
                    }
                }
            }
        }
        .onAppear { store.beginSampling() }
        .onDisappear { store.endSampling() }
    }

    private func item(_ metric: Metric) -> some View {
        Label {
            Text(metric.shortValue ?? metric.value)
        } icon: {
            Image(systemName: metric.symbol)
                .foregroundStyle(metric.tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
        }
        .font(.callout.monospacedDigit())
        .lineLimit(1)
        .fixedSize()
        .help(metric.title)
    }
}

private struct SystemSettings: View {
    @AppStorage(showsCPUKey) private var showsCPU = true
    @AppStorage(showsMemoryKey) private var showsMemory = true
    @AppStorage(showsDiskKey) private var showsDisk = true
    @AppStorage(showsBatteryKey) private var showsBattery = true
    @AppStorage(showsMemoryPercentKey) private var showsMemoryPercent = true
    @AppStorage(showsDiskPercentKey) private var showsDiskPercent = true
    @AppStorage(sampleSecondsKey) private var sampleSeconds = defaultSampleSeconds
    @AppStorage(showsGraphsKey) private var showsGraphs = true
    @AppStorage(showsLowBatteryHeadsUpKey) private var showsLowBatteryHeadsUp = true
    @AppStorage(lowBatteryThresholdKey) private var lowBatteryThreshold = defaultLowBatteryThreshold

    var body: some View {
        Form {
            Section("Metrics") {
                Toggle("CPU", isOn: $showsCPU)
                Toggle("Memory", isOn: $showsMemory)
                Picker("Show memory as", selection: $showsMemoryPercent) {
                    Text("Pressure (%)").tag(true)
                    Text("Amount in use").tag(false)
                }
                .disabled(!showsMemory)
                Toggle("Disk", isOn: $showsDisk)
                Picker("Show disk as", selection: $showsDiskPercent) {
                    Text("Used (%)").tag(true)
                    Text("Free space").tag(false)
                }
                .disabled(!showsDisk)
                Toggle("Battery", isOn: $showsBattery)
                Toggle("Graph the last minute of CPU and memory pressure", isOn: $showsGraphs)
            }
            Section {
                Picker("Update every", selection: $sampleSeconds) {
                    ForEach([1, 2, 3, 5, 10], id: \.self) { Text("\($0) s").tag($0) }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("CocoNotch reads these only while the System tab or its Home card is on screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Low battery heads-up") {
                Toggle("Show a heads-up in the closed notch when the battery is low", isOn: $showsLowBatteryHeadsUp)
                Picker("When the battery reaches", selection: $lowBatteryThreshold) {
                    ForEach([10, 15, 20, 30], id: \.self) { Text("\($0)%").tag($0) }
                }
                .disabled(!showsLowBatteryHeadsUp)
            }
        }
        .formStyle(.grouped)
    }
}
