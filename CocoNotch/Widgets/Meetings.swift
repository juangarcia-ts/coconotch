import CocoNotchCore
import EventKit
import SwiftUI

extension NotchWidget {
    static let meetings = NotchWidget(
        id: "meetings",
        title: "Meetings",
        systemImage: "calendar",
        makeView: { AnyView(MeetingsView()) },
        makeSettings: { AnyView(MeetingsSettings()) }
    )
}

private let hidesAllDayKey = "meetings.hidesAllDay"
private let hidesDeclinedKey = "meetings.hidesDeclined"
private let hiddenCalendarIDsKey = "meetings.hiddenCalendarIDs"
private let agendaLimit = 3

// One store for the whole app: Apple recommends reusing it, and creating one is slow.
private let eventStore = EKEventStore()

private func getTodaysMeetings(now: Date) -> [Meeting] {
    let startOfDay = Calendar.current.startOfDay(for: now)
    guard let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay) else { return [] }
    let predicate = eventStore.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
    return eventStore.events(matching: predicate).map { event in
        Meeting(
            // Occurrences of a repeating event share an identifier, so the start time keeps each one unique.
            id: "\(event.eventIdentifier ?? "")-\(event.startDate.timeIntervalSince1970)",
            title: event.title ?? "Untitled",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            calendarID: event.calendar?.calendarIdentifier ?? "",
            isDeclined: event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined,
            link: findMeetingLink(in: [event.url?.absoluteString, event.location, event.notes])
        )
    }
}

private func formatTimeRange(_ meeting: Meeting) -> String {
    guard !meeting.isAllDay else { return "All day" }
    let start = meeting.start.formatted(date: .omitted, time: .shortened)
    return "\(start)–\(meeting.end.formatted(date: .omitted, time: .shortened))"
}

private struct MeetingsView: View {
    @AppStorage(hidesAllDayKey) private var hidesAllDay = true
    @AppStorage(hidesDeclinedKey) private var hidesDeclined = true
    @AppStorage(hiddenCalendarIDsKey) private var storedHiddenCalendarIDs = ""
    @State private var accessStatus = EKEventStore.authorizationStatus(for: .event)

    var body: some View {
        Group {
            switch accessStatus {
            case .fullAccess:
                agenda
            case .notDetermined:
                VStack(spacing: 10) {
                    Text("See your next meetings and join them from the notch.")
                        .foregroundStyle(.secondary)
                    Button("Allow Calendar Access") {
                        Task { await requestAccess() }
                    }
                }
            default:
                VStack(spacing: 10) {
                    Text("CocoNotch can't read your calendars.")
                        .foregroundStyle(.secondary)
                    Button("Open Privacy Settings") {
                        if let url = URL(
                            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
                        {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        // Access may have been granted in System Settings since the notch last opened.
        .onAppear { accessStatus = EKEventStore.authorizationStatus(for: .event) }
    }

    private var agenda: some View {
        TimelineView(.everyMinute) { context in
            let upcoming = getUpcomingMeetings(
                getTodaysMeetings(now: context.date),
                now: context.date,
                hidesAllDay: hidesAllDay,
                hidesDeclined: hidesDeclined,
                hiddenCalendarIDs: decodeIDSet(storedHiddenCalendarIDs)
            )
            if let next = upcoming.first {
                VStack(alignment: .leading, spacing: 10) {
                    NextMeetingCard(meeting: next, now: context.date)
                    ForEach(upcoming.dropFirst().prefix(agendaLimit)) { meeting in
                        MeetingRow(meeting: meeting)
                    }
                    let remaining = upcoming.count - 1 - agendaLimit
                    if remaining > 0 {
                        Text("+\(remaining) more today")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("No more meetings today")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
        }
    }

    private func requestAccess() async {
        _ = try? await eventStore.requestFullAccessToEvents()
        accessStatus = EKEventStore.authorizationStatus(for: .event)
    }
}

private struct NextMeetingCard: View {
    let meeting: Meeting
    let now: Date

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(formatTimeRange(meeting)) · \(formatCountdown(now: now, start: meeting.start))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let link = meeting.link {
                Link(destination: link) {
                    Label("Join", systemImage: "video.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        HStack(spacing: 10) {
            Text(meeting.isAllDay ? "All day" : meeting.start.formatted(date: .omitted, time: .shortened))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(meeting.title)
                .lineLimit(1)
            Spacer()
            if let link = meeting.link {
                Link(destination: link) {
                    Image(systemName: "video")
                }
                .help("Join")
            }
        }
        .padding(.horizontal, 10)
    }
}

private struct MeetingsSettings: View {
    @AppStorage(hidesAllDayKey) private var hidesAllDay = true
    @AppStorage(hidesDeclinedKey) private var hidesDeclined = true
    @AppStorage(hiddenCalendarIDsKey) private var storedHiddenCalendarIDs = ""

    var body: some View {
        Form {
            Toggle("Hide all-day events", isOn: $hidesAllDay)
            Toggle("Hide events I declined", isOn: $hidesDeclined)
            Section("Calendars") {
                if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
                    Text("Open the Meetings tab in the notch and allow calendar access to choose calendars here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(eventStore.calendars(for: .event), id: \.calendarIdentifier) { calendar in
                    Toggle(isOn: makeVisibilityBinding(for: calendar.calendarIdentifier)) {
                        HStack {
                            Circle()
                                .fill(Color(nsColor: calendar.color ?? .gray))
                                .frame(width: 8, height: 8)
                            Text(calendar.title)
                            Text(calendar.source?.title ?? "")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // Stores hidden calendars rather than shown ones, so calendars added later appear by default.
    private func makeVisibilityBinding(for calendarID: String) -> Binding<Bool> {
        Binding(
            get: { !decodeIDSet(storedHiddenCalendarIDs).contains(calendarID) },
            set: { isVisible in
                var hiddenIDs = decodeIDSet(storedHiddenCalendarIDs)
                if isVisible {
                    hiddenIDs.remove(calendarID)
                } else {
                    hiddenIDs.insert(calendarID)
                }
                storedHiddenCalendarIDs = encodeIDSet(hiddenIDs)
            }
        )
    }
}
