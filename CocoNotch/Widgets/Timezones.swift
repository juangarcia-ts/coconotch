import CocoNotchCore
import SwiftUI

extension NotchWidget {
    static let timezones = NotchWidget(
        id: "timezones",
        title: "Time Zones",
        systemImage: "globe",
        makeView: { AnyView(TimezonesView()) },
        makeMenuItems: { AnyView(TimezonesMenu()) }
    )
}

private let storageKey = "timezones.identifiers"
private let defaultIdentifiers = "America/Los_Angeles,America/New_York,Europe/London,Asia/Tokyo"

private struct TimezonesView: View {
    @AppStorage(storageKey) private var storedIdentifiers = defaultIdentifiers
    @State private var hourOffset = 0.0

    private var zones: [TimeZone] {
        let local = TimeZone.current
        let others = parseTimeZoneIdentifiers(storedIdentifiers)
            .filter { $0 != local.identifier }
            .compactMap(TimeZone.init(identifier:))
        return [local] + others
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let date = context.date.addingTimeInterval(hourOffset * 3600)
            VStack(spacing: 14) {
                HStack(spacing: 0) {
                    ForEach(zones, id: \.identifier) { zone in
                        ZoneColumn(zone: zone, date: date)
                            .frame(maxWidth: .infinity)
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
    let date: Date

    private var isLocal: Bool { zone == .current }

    private var detail: String {
        let weekday = date.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated))
        let offset = zone.secondsFromGMT(for: date) - TimeZone.current.secondsFromGMT(for: date)
        return "\(weekday) · \(isLocal ? "Here" : formatOffset(seconds: offset))"
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(getCityName(forTimeZoneIdentifier: zone.identifier))
                .font(.caption)
                .foregroundStyle(isLocal ? .primary : .secondary)
                .lineLimit(1)
            Text(date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone)))
                .font(.title2.weight(.semibold).monospacedDigit())
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct TimezonesMenu: View {
    @AppStorage(storageKey) private var storedIdentifiers = defaultIdentifiers

    private static let identifiersByRegion = Dictionary(
        grouping: TimeZone.knownTimeZoneIdentifiers.filter { $0.contains("/") },
        by: { String($0.split(separator: "/")[0]) }
    )

    var body: some View {
        let identifiers = parseTimeZoneIdentifiers(storedIdentifiers)
        ForEach(identifiers, id: \.self) { identifier in
            Button("Remove \(getCityName(forTimeZoneIdentifier: identifier))") {
                storedIdentifiers = identifiers.filter { $0 != identifier }.joined(separator: ",")
            }
        }
        Divider()
        Menu("Add") {
            ForEach(Self.identifiersByRegion.keys.sorted(), id: \.self) { region in
                Menu(region) {
                    ForEach(Self.identifiersByRegion[region] ?? [], id: \.self) { identifier in
                        Button(getCityName(forTimeZoneIdentifier: identifier)) {
                            storedIdentifiers = (identifiers + [identifier]).joined(separator: ",")
                        }
                        .disabled(identifiers.contains(identifier))
                    }
                }
            }
        }
    }
}
