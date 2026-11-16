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

/// Loads today's meetings for the whole app, so the closed notch can use them too, not just the Meetings tab.
@Observable
final class MeetingsStore {
    static let shared = MeetingsStore()

    private(set) var accessStatus = EKEventStore.authorizationStatus(for: .event)
    // Fetched once a minute and when calendars change, not on every render.
    private(set) var todaysMeetings: [Meeting] = []
    private var refreshTask: Task<Void, Never>?

    /// Starts the once-a-minute refresh. Never asks for access; that happens from the Meetings tab.
    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshAccessStatus()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: eventStore, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccessStatus() }
        }
    }

    /// Re-reads access, which the user may have changed in System Settings, then reloads meetings.
    func refreshAccessStatus() {
        accessStatus = EKEventStore.authorizationStatus(for: .event)
        todaysMeetings = accessStatus == .fullAccess ? getTodaysMeetings(now: .now) : []
    }

    func requestAccess() async {
        _ = try? await eventStore.requestFullAccessToEvents()
        refreshAccessStatus()
    }
}

private struct MeetingsView: View {
    @AppStorage(hidesAllDayKey) private var hidesAllDay = true
    @AppStorage(hidesDeclinedKey) private var hidesDeclined = true
    @AppStorage(hiddenCalendarIDsKey) private var storedHiddenCalendarIDs = ""
    private let store = MeetingsStore.shared

    var body: some View {
        Group {
            switch store.accessStatus {
            case .fullAccess:
                agenda
            case .notDetermined:
                VStack(spacing: 10) {
                    Text("See your next meetings and join them from the notch.")
                        .foregroundStyle(.secondary)
                    Button("Allow Calendar Access") {
                        Task { await store.requestAccess() }
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
        .onAppear { store.refreshAccessStatus() }
    }

    private var agenda: some View {
        TimelineView(.everyMinute) { context in
            let agenda = makeAgenda(
                getUpcomingMeetings(
                    store.todaysMeetings,
                    now: context.date,
                    hidesAllDay: hidesAllDay,
                    hidesDeclined: hidesDeclined,
                    hiddenCalendarIDs: decodeIDSet(storedHiddenCalendarIDs)
                ),
                limit: agendaLimit
            )
            if let next = agenda.next {
                VStack(alignment: .leading, spacing: 10) {
                    NextMeetingCard(meeting: next, now: context.date)
                    ForEach(agenda.rest) { meeting in
                        MeetingRow(meeting: meeting)
                    }
                    if agenda.hiddenCount > 0 {
                        Text("+\(agenda.hiddenCount) more today")
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
            Text(formatStartTime(meeting))
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
