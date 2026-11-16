import CocoNotchCore
import SwiftUI

extension NotchWidget {
    static let timezones = NotchWidget(
        id: "timezones",
        title: "Time Zones",
        systemImage: "globe",
        makeView: { AnyView(TimezonesView()) },
        makeSettings: { AnyView(TimezonesSettings()) },
        makeSummary: { AnyView(TimezonesSummary()) },
        makeSummarySettings: { AnyView(TimezonesSummarySettings()) }
    )
}

// Kept from 0.1, which stored a comma-separated list here; decodeTimeZoneEntries still reads that format.
private let entriesKey = "timezones.identifiers"
private let showsFlagsKey = "timezones.showsFlags"
private let homeCountKey = "timezones.homeCount"
private let defaultHomeCount = 3
private let defaultStoredEntries = encodeTimeZoneEntries(
    ["America/Los_Angeles", "America/New_York", "Europe/London", "Asia/Tokyo"].map { TimeZoneEntry(identifier: $0) }
)

private let countryCodesByTimeZone = parseZoneTab(
    (try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8)) ?? ""
)

private func getFlag(forTimeZoneIdentifier identifier: String) -> String? {
    countryCodesByTimeZone[identifier].flatMap { getFlagEmoji(countryCode: $0) }
}

private func getZoneTitle(identifier: String, label: String?, showsFlag: Bool) -> String {
    getDisplayTitle(
        label: label,
        identifier: identifier,
        flag: showsFlag ? getFlag(forTimeZoneIdentifier: identifier) : nil
    )
}

private struct TimezonesView: View {
    @AppStorage(entriesKey) private var storedEntries = defaultStoredEntries
    @AppStorage(showsFlagsKey) private var showsFlags = true
    @State private var hourOffset = 0.0

    private var otherEntries: [TimeZoneEntry] {
        getVisibleEntries(decodeTimeZoneEntries(storedEntries), localIdentifier: TimeZone.current.identifier)
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let date = context.date.addingTimeInterval(hourOffset * 3600)
            VStack(spacing: 14) {
                HStack(spacing: 0) {
                    ZoneColumn(zone: .current, label: nil, showsFlag: showsFlags, date: date)
                    ForEach(otherEntries) { entry in
                        if let zone = TimeZone(identifier: entry.identifier) {
                            ZoneColumn(zone: zone, label: entry.label, showsFlag: showsFlags, date: date)
                        }
                    }
                }
                HStack(spacing: 10) {
                    Slider(value: $hourOffset, in: -12...12, step: 0.5)
                        .controlSize(.small)
                    Button(hourOffset == 0 ? "Now" : formatOffset(seconds: Int(hourOffset * 3600))) {
                        hourOffset = 0
                    }
                    .buttonStyle(.plain)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
                    .help("Back to now")
                }
            }
        }
    }
}

private struct ZoneColumn: View {
    let zone: TimeZone
    let label: String?
    let showsFlag: Bool
    let date: Date

    private var isLocal: Bool { zone == .current }

    private var title: String {
        getZoneTitle(identifier: zone.identifier, label: label, showsFlag: showsFlag)
    }

    private var detail: String {
        let weekday = date.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated))
        let offset = zone.secondsFromGMT(for: date) - TimeZone.current.secondsFromGMT(for: date)
        return "\(weekday) · \(isLocal ? "Here" : formatOffset(seconds: offset))"
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(isLocal ? .primary : .secondary)
                .lineLimit(1)
            Text(date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone)))
                .font(.title2.weight(.semibold).monospacedDigit())
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The first few other time zones, for the Home tab.
private struct TimezonesSummary: View {
    @AppStorage(entriesKey) private var storedEntries = defaultStoredEntries
    @AppStorage(showsFlagsKey) private var showsFlags = true
    @AppStorage(homeCountKey) private var homeCount = defaultHomeCount

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 0) {
                ForEach(
                    getVisibleEntries(
                        decodeTimeZoneEntries(storedEntries), localIdentifier: TimeZone.current.identifier
                    ).prefix(homeCount)
                ) { entry in
                    if let zone = TimeZone(identifier: entry.identifier) {
                        VStack(spacing: 2) {
                            Text(
                                context.date.formatted(
                                    Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
                            )
                            .font(.title3.weight(.semibold).monospacedDigit())
                            Text(getZoneTitle(identifier: entry.identifier, label: entry.label, showsFlag: showsFlags))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(
                                formatOffset(
                                    seconds: zone.secondsFromGMT(for: context.date)
                                        - TimeZone.current.secondsFromGMT(for: context.date))
                            )
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

private struct TimezonesSummarySettings: View {
    @AppStorage(homeCountKey) private var homeCount = defaultHomeCount

    var body: some View {
        Picker("Cities shown", selection: $homeCount) {
            ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
        }
    }
}

private struct TimezonesSettings: View {
    @AppStorage(entriesKey) private var storedEntries = defaultStoredEntries
    @AppStorage(showsFlagsKey) private var showsFlags = true
    // Decoded once when the tab appears and saved on every change, instead of decoding on each access.
    @State private var entries: [TimeZoneEntry] = []
    @State private var query = ""

    private var suggestions: [String] {
        searchTimeZoneIdentifiers(
            query,
            in: TimeZone.knownTimeZoneIdentifiers,
            excluding: Set(entries.map(\.identifier)),
            limit: 6
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show country flags", isOn: $showsFlags)
            Text("Your local time is always shown first. Drag to reorder; the label replaces the city name.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach($entries) { $entry in
                    let isLocal = entry.identifier == TimeZone.current.identifier
                    HStack {
                        DragHandle()
                        Toggle("Show \(getCityName(forTimeZoneIdentifier: entry.identifier))", isOn: $entry.isVisible)
                            .labelsHidden()
                            .disabled(isLocal)
                        Text(getFlag(forTimeZoneIdentifier: entry.identifier) ?? "")
                            .frame(width: 22)
                        TextField(
                            getCityName(forTimeZoneIdentifier: entry.identifier),
                            text: Binding(get: { entry.label ?? "" }, set: { entry.label = normalizeLabel($0) })
                        )
                        .disabled(isLocal)
                        if isLocal {
                            Text("Your local time")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Remove", systemImage: "minus.circle") {
                            entries.removeAll { $0.id == entry.id }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
                .onMove { entries.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(height: 200)

            TextField("Add a city…", text: $query)
                .onSubmit {
                    if let identifier = suggestions.first { add(identifier) }
                }
            ForEach(suggestions, id: \.self) { identifier in
                Button {
                    add(identifier)
                } label: {
                    Text("\(getFlag(forTimeZoneIdentifier: identifier) ?? "") \(identifier)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(20)
        .frame(minHeight: 420, alignment: .top)
        .onAppear { entries = decodeTimeZoneEntries(storedEntries) }
        .onChange(of: entries) { storedEntries = encodeTimeZoneEntries(entries) }
    }

    private func add(_ identifier: String) {
        entries.append(TimeZoneEntry(identifier: identifier))
        query = ""
    }
}
