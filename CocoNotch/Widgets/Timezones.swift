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
    [localTimeZoneEntryID, "America/Los_Angeles", "America/New_York", "Europe/London", "Asia/Tokyo"].map {
        TimeZoneEntry(identifier: $0)
    }
)

private let countryCodesByTimeZone = parseZoneTab(
    (try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8)) ?? ""
)

private func getFlag(forTimeZoneIdentifier identifier: String) -> String? {
    countryCodesByTimeZone[identifier].flatMap { getFlagEmoji(countryCode: $0) }
}

private func getZone(for entry: TimeZoneEntry) -> TimeZone? {
    TimeZone(
        identifier: resolveTimeZoneIdentifier(
            entry.identifier, localIdentifier: TimeZone.autoupdatingCurrent.identifier))
}

private func getZoneTitle(identifier: String, label: String?) -> String {
    getDisplayTitle(label: label, identifier: identifier)
}

private struct TimezonesView: View {
    @AppStorage(entriesKey) private var storedEntries = defaultStoredEntries
    @AppStorage(showsFlagsKey) private var showsFlags = true
    @State private var hourOffset = 0.0

    private var entries: [TimeZoneEntry] {
        getVisibleEntries(
            decodeTimeZoneEntries(storedEntries),
            localIdentifier: TimeZone.autoupdatingCurrent.identifier
        )
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let date = context.date.addingTimeInterval(hourOffset * 3600)
            VStack(spacing: 14) {
                HStack(spacing: 0) {
                    ForEach(entries) { entry in
                        if let zone = getZone(for: entry) {
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

    private var isLocal: Bool { zone.identifier == TimeZone.autoupdatingCurrent.identifier }

    private var title: String {
        getZoneTitle(identifier: zone.identifier, label: label)
    }

    private var detail: String {
        let weekday = date.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated))
        let offset = zone.secondsFromGMT(for: date) - TimeZone.autoupdatingCurrent.secondsFromGMT(for: date)
        return "\(weekday) · \(formatOffsetLabel(seconds: offset, isLocal: isLocal))"
    }

    var body: some View {
        // Same order as the Home card: flag, time, place, then the day and offset.
        VStack(spacing: 2) {
            if showsFlag, let flag = getFlag(forTimeZoneIdentifier: zone.identifier) {
                Text(flag)
                    .font(.title3)
            }
            Text(date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone)))
                .font(.title2.weight(.semibold).monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(isLocal ? .primary : .secondary)
                .lineLimit(1)
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
                        decodeTimeZoneEntries(storedEntries),
                        localIdentifier: TimeZone.autoupdatingCurrent.identifier
                    ).prefix(homeCount)
                ) { entry in
                    if let zone = getZone(for: entry) {
                        VStack(spacing: 0) {
                            if showsFlags, let flag = getFlag(forTimeZoneIdentifier: zone.identifier) {
                                Text(flag)
                                    .font(.caption)
                            }
                            Text(
                                context.date.formatted(
                                    Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
                            )
                            .font(.headline.monospacedDigit())
                            Text(getZoneTitle(identifier: zone.identifier, label: entry.label))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(
                                formatOffsetLabel(
                                    seconds: zone.secondsFromGMT(for: context.date)
                                        - TimeZone.autoupdatingCurrent.secondsFromGMT(for: context.date),
                                    isLocal: zone.identifier == TimeZone.autoupdatingCurrent.identifier
                                )
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
    /// The entry whose alias is being typed; the others show their name as plain text.
    @State private var editingID: String?
    /// Which row's alias field has focus. Per row rather than one flag, so moving from one row's field to another's
    /// doesn't read as clicking away and close the new one.
    @FocusState private var focusedAliasID: String?

    private var suggestions: [String] {
        searchTimeZoneIdentifiers(
            query,
            in: TimeZone.knownTimeZoneIdentifiers,
            excluding: getAddedTimeZoneIdentifiers(entries, localIdentifier: TimeZone.autoupdatingCurrent.identifier),
            limit: 6
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show country flags", isOn: $showsFlags)
            Text(
                "Drag to reorder. Double-click a name or use ✎ to give it an alias. Your current time zone follows your Mac when you travel."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            List {
                ForEach($entries) { $entry in
                    let isLocal = entry.identifier == localTimeZoneEntryID
                    let identifier = resolveTimeZoneIdentifier(
                        entry.identifier, localIdentifier: TimeZone.autoupdatingCurrent.identifier)
                    HStack {
                        DragHandle()
                        Toggle("Show \(getCityName(forTimeZoneIdentifier: identifier))", isOn: $entry.isVisible)
                            .labelsHidden()
                        Text(getFlag(forTimeZoneIdentifier: identifier) ?? "")
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            if editingID == entry.id {
                                TextField(
                                    "Alias",
                                    text: Binding(
                                        get: { entry.label ?? "" }, set: { entry.label = normalizeLabel($0) }),
                                    prompt: Text(getCityName(forTimeZoneIdentifier: identifier))
                                )
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                                .focused($focusedAliasID, equals: entry.id)
                                .onSubmit { editingID = nil }
                                .onAppear { focusedAliasID = entry.id }
                            } else {
                                Text(getDisplayTitle(label: entry.label, identifier: identifier))
                                    .onTapGesture(count: 2) { editingID = entry.id }
                            }
                            // Names the real zone, which an alias would otherwise hide.
                            Text(
                                formatTimeZoneCaption(
                                    identifier: identifier,
                                    abbreviation: TimeZone(identifier: identifier)?.abbreviation(),
                                    isLocal: isLocal
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                        Spacer()
                        Button("Rename", systemImage: "pencil") { editingID = entry.id }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Set an alias; leave it empty to use the city's name")
                        Button("Remove", systemImage: "minus.circle") {
                            entries.removeAll { $0.id == entry.id }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        // Hide it instead; there would be no way to add it back.
                        .disabled(isLocal)
                    }
                }
                .onMove { entries.move(fromOffsets: $0, toOffset: $1) }
            }
            // Clicking away from an alias saves it, like Return. Focus moving to another row's field leaves that row open.
            .onChange(of: focusedAliasID) { lost, gained in
                if gained == nil, lost == editingID { editingID = nil }
            }
            .frame(height: 200)

            TextField("Add a time zone…", text: $query)
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
        .onAppear {
            entries = decodeTimeZoneEntries(storedEntries)
        }
        .onChange(of: entries) { storedEntries = encodeTimeZoneEntries(entries) }
    }

    private func add(_ identifier: String) {
        entries.append(TimeZoneEntry(identifier: identifier))
        query = ""
    }
}
