import CocoNotchCore
import SwiftUI

extension NotchWidget {
    static let timezones = NotchWidget(
        id: "timezones",
        title: String(localized: "Time Zones"),
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
// Off by default: the day band and sun or moon already say what a flag would, more quietly.
private let defaultShowsFlags = false
private let defaultHomeCount = maxHomeTimeZoneCount
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

private let nightColor = Color(red: 0.22, green: 0.26, blue: 0.46)
private let dayColor = Color(red: 0.98, green: 0.79, blue: 0.45)

/// The time with AM or PM set smaller, so the digits carry the weight.
private func formatTime(_ date: Date, in zone: TimeZone, periodFont: Font) -> AttributedString {
    var text = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone).attributedStyle)
    let periods = text.runs.compactMap { $0.foundation.dateField == .amPM ? $0.range : nil }
    for range in periods {
        text[range].font = periodFont
        text[range].foregroundColor = .secondary
    }
    return text
}

/// The offset from here, plus "Tomorrow" or "Yesterday" when the date differs.
private func getZoneCaption(_ zone: TimeZone, at date: Date) -> String {
    let local = TimeZone.autoupdatingCurrent
    let offset = formatOffsetLabel(
        seconds: zone.secondsFromGMT(for: date) - local.secondsFromGMT(for: date),
        isLocal: zone.identifier == local.identifier)
    return [offset, formatRelativeDay(at: date, in: zone, localZone: local)].compactMap { $0 }.joined(separator: " · ")
}

private struct DaySymbol: View {
    let hour: Double

    var body: some View {
        let isDay = isDaytime(hour: hour)
        Image(systemName: isDay ? "sun.max.fill" : "moon.fill")
            .foregroundStyle(isDay ? dayColor : Color(red: 0.62, green: 0.67, blue: 0.95))
            .help(isDay ? String(localized: "Daytime") : String(localized: "Night"))
    }
}

private struct TimezonesView: View {
    @AppStorage(entriesKey) private var storedEntries = defaultStoredEntries
    @AppStorage(showsFlagsKey) private var showsFlags = defaultShowsFlags
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
            VStack(spacing: 12) {
                ForEach(entries) { entry in
                    if let zone = getZone(for: entry) {
                        ZoneRow(
                            zone: zone, label: entry.label, showsFlag: showsFlags, now: context.date, date: date,
                            hourOffset: $hourOffset)
                    }
                }
                HStack {
                    Spacer()
                    if hourOffset == 0 {
                        Text("Drag a timeline to look ahead or back.")
                            .foregroundStyle(.tertiary)
                    } else {
                        Button {
                            hourOffset = 0
                        } label: {
                            Label {
                                HStack(spacing: 4) {
                                    Text("Back to now")
                                    Text(verbatim: "(\(formatOffset(seconds: Int(hourOffset * 3600))))")
                                }
                            } icon: {
                                Image(systemName: "arrow.uturn.backward")
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .font(.caption.monospacedDigit())
            }
        }
    }
}

private struct ZoneRow: View {
    let zone: TimeZone
    let label: String?
    let showsFlag: Bool
    let now: Date
    /// The moment shown, which differs from `now` while the timeline is dragged.
    let date: Date
    @Binding var hourOffset: Double

    private var isLocal: Bool { zone.identifier == TimeZone.autoupdatingCurrent.identifier }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if showsFlag, let flag = getFlag(forTimeZoneIdentifier: zone.identifier) {
                        Text(flag)
                    }
                    Text(getZoneTitle(identifier: zone.identifier, label: label))
                        .fontWeight(isLocal ? .semibold : .regular)
                }
                .font(.callout)
                Text(getZoneCaption(zone, at: date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .frame(width: 150, alignment: .leading)
            DayBand(zone: zone, now: now, hourOffset: $hourOffset)
            HStack(spacing: 8) {
                DaySymbol(hour: getLocalHour(at: date, in: zone))
                    .font(.caption)
                Text(formatTime(date, in: zone, periodFont: .system(.callout, design: .rounded)))
                    .font(.system(.title2, design: .rounded, weight: .light).monospacedDigit())
                    .contentTransition(.numericText())
            }
            .lineLimit(1)
            .frame(width: 130, alignment: .trailing)
        }
    }
}

/// A day around now in one zone, tinted from night to day, with a tick at local midnight and the line being dragged.
private struct DayBand: View {
    let zone: TimeZone
    let now: Date
    @Binding var hourOffset: Double

    var body: some View {
        let startHour = getLocalHour(at: now.addingTimeInterval(-timelineHalfSpan * 3600), in: zone)
        let hourCount = Int(timelineHalfSpan * 2)
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(
                        LinearGradient(
                            stops: (0...hourCount).map { hour in
                                Gradient.Stop(
                                    color: nightColor.mix(
                                        with: dayColor, by: getDaylight(hour: startHour + Double(hour))),
                                    location: Double(hour) / Double(hourCount))
                            },
                            startPoint: .leading, endPoint: .trailing)
                    )
                    .opacity(0.75)
                Rectangle()
                    .fill(.primary.opacity(0.4))
                    .frame(width: 1)
                    .offset(x: width * getMidnightFraction(startHour: startHour))
                Capsule()
                    .fill(.primary)
                    .frame(width: 2, height: geometry.size.height + 10)
                    .offset(x: width * (0.5 + hourOffset / (timelineHalfSpan * 2)) - 1)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle().inset(by: -8))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { hourOffset = getScrubHourOffset(fraction: $0.location.x / width) }
            )
            .animation(.snappy(duration: 0.2), value: hourOffset)
        }
        .frame(height: 8)
        .help("Drag to look ahead or back")
    }
}

/// The first few other time zones, for the Home tab.
private struct TimezonesSummary: View {
    @AppStorage(entriesKey) private var storedEntries = defaultStoredEntries
    @AppStorage(showsFlagsKey) private var showsFlags = defaultShowsFlags
    @AppStorage(homeCountKey) private var homeCount = defaultHomeCount

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 8) {
                ForEach(
                    getHomeEntries(
                        decodeTimeZoneEntries(storedEntries),
                        localIdentifier: TimeZone.autoupdatingCurrent.identifier,
                        count: homeCount
                    )
                ) { entry in
                    if let zone = getZone(for: entry) {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: 4) {
                                    if showsFlags, let flag = getFlag(forTimeZoneIdentifier: zone.identifier) {
                                        Text(flag)
                                    }
                                    Text(getZoneTitle(identifier: zone.identifier, label: entry.label))
                                }
                                .font(.caption.weight(.medium))
                                Text(getZoneCaption(zone, at: context.date))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            .lineLimit(1)
                            Spacer(minLength: 6)
                            DaySymbol(hour: getLocalHour(at: context.date, in: zone))
                                .font(.caption2)
                            Text(formatTime(context.date, in: zone, periodFont: .system(.caption, design: .rounded)))
                                .font(.system(.title3, design: .rounded, weight: .light).monospacedDigit())
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                }
            }
        }
    }
}

private struct TimezonesSummarySettings: View {
    @AppStorage(homeCountKey) private var homeCount = defaultHomeCount

    var body: some View {
        Picker(
            "Cities shown",
            selection: Binding(get: { clampHomeTimeZoneCount(homeCount) }, set: { homeCount = $0 })
        ) {
            ForEach(1...maxHomeTimeZoneCount, id: \.self) { Text("\($0)").tag($0) }
        }
    }
}

private struct TimezonesSettings: View {
    @AppStorage(entriesKey) private var storedEntries = defaultStoredEntries
    @AppStorage(showsFlagsKey) private var showsFlags = defaultShowsFlags
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
            HStack {
                Text("Show country flags")
                Spacer()
                Toggle("Show country flags", isOn: $showsFlags)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
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
                        if showsFlags {
                            Text(getFlag(forTimeZoneIdentifier: identifier) ?? "")
                                .frame(width: 22)
                        }
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
                        Toggle("Show \(getCityName(forTimeZoneIdentifier: identifier))", isOn: $entry.isVisible)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    .listRowInsets(settingsListRowInsets)
                }
                .onMove { entries.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
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
                    Text(
                        verbatim: [showsFlags ? getFlag(forTimeZoneIdentifier: identifier) : nil, identifier]
                            .compactMap { $0 }.joined(separator: " ")
                    )
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
