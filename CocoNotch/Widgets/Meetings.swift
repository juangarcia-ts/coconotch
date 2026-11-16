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
private let headsUpMinutesKey = "meetings.headsUpMinutes"
private let showsPastEventsKey = "meetings.showsPastEvents"
private let agendaLimit = 3
private let defaultHidesAllDay = true
private let defaultHidesDeclined = true
private let defaultHeadsUpMinutes = 10
private let defaultShowsPastEvents = false
private let headsUpGrace: TimeInterval = 10 * 60
private let headsUpActivityID = "meetings.headsUp"

// One store for the whole app: Apple recommends reusing it, and creating one is slow.
private let eventStore = EKEventStore()

private func getMeetings(on day: Date) -> [Meeting] {
    guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
        let interval = getDayInterval(for: day, calendar: .current)
    else { return [] }
    let predicate = eventStore.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
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
    /// The day picked in the Meetings tab; nil follows today. The heads-up always uses today.
    private(set) var selectedDay: Date?
    private(set) var selectedDaysMeetings: [Meeting] = []
    private var refreshTask: Task<Void, Never>?
    /// The meeting shown in the closed notch, if any.
    private(set) var headsUpMeetingID: String?
    private var dismissedHeadsUpIDs: Set<String> = []
    private(set) var isRefreshing = false

    /// Reloads meetings once a minute and re-checks the heads-up every 15 seconds, so it turns urgent close to the
    /// start time without querying EventKit that often. Never asks for access; that happens from the Meetings tab.
    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshAccessStatus()
                for _ in 0..<4 {
                    try? await Task.sleep(for: .seconds(15))
                    self?.updateHeadsUp()
                }
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
        todaysMeetings = getMeetings(on: .now)
        loadSelectedDay()
        updateHeadsUp()
    }

    func select(_ day: Date) {
        selectedDay = getSelectedDay(picked: day, now: .now, calendar: .current)
        loadSelectedDay()
    }

    private func loadSelectedDay() {
        selectedDaysMeetings = selectedDay.map(getMeetings(on:)) ?? todaysMeetings
    }

    func dismissHeadsUp() {
        if let headsUpMeetingID { dismissedHeadsUpIDs.insert(headsUpMeetingID) }
        updateHeadsUp()
    }

    private func updateHeadsUp() {
        let now = Date.now
        let defaults = UserDefaults.standard
        let upcoming = getUpcomingMeetings(
            todaysMeetings,
            now: now,
            hidesAllDay: defaults.object(forKey: hidesAllDayKey) as? Bool ?? defaultHidesAllDay,
            hidesDeclined: defaults.object(forKey: hidesDeclinedKey) as? Bool ?? defaultHidesDeclined,
            hiddenCalendarIDs: decodeIDSet(defaults.string(forKey: hiddenCalendarIDsKey) ?? "")
        )
        let leadMinutes = defaults.object(forKey: headsUpMinutesKey) as? Int ?? defaultHeadsUpMinutes
        let meeting = getHeadsUpMeeting(
            upcoming,
            now: now,
            leadTime: TimeInterval(leadMinutes * 60),
            grace: headsUpGrace,
            dismissedIDs: dismissedHeadsUpIDs
        )
        headsUpMeetingID = meeting?.id
        guard let meeting else {
            ActivityCenter.shared.remove(id: headsUpActivityID)
            return
        }
        ActivityCenter.shared.post(
            NotchActivity(
                id: headsUpActivityID,
                widgetID: NotchWidget.meetings.id,
                priority: getHeadsUpPriority(start: meeting.start, now: now),
                sortDate: meeting.start,
                makeLeading: { AnyView(HeadsUpTitle(meeting: meeting)) },
                makeTrailing: { AnyView(HeadsUpCountdown(meeting: meeting)) },
                makeAlert: { AnyView(HeadsUpAlert(meeting: meeting)) }
            )
        )
    }

    /// Asks remote calendars such as Google to sync now; `EKEventStoreChanged` reloads meetings if anything changed.
    func refresh() async {
        isRefreshing = true
        eventStore.refreshSourcesIfNecessary()
        // The sync runs in the background with no completion callback, so give it a moment before reloading.
        try? await Task.sleep(for: .seconds(2))
        refreshAccessStatus()
        isRefreshing = false
    }

    func requestAccess() async {
        _ = try? await eventStore.requestFullAccessToEvents()
        refreshAccessStatus()
    }
}

private struct MeetingsView: View {
    @AppStorage(hidesAllDayKey) private var hidesAllDay = defaultHidesAllDay
    @AppStorage(hidesDeclinedKey) private var hidesDeclined = defaultHidesDeclined
    @AppStorage(hiddenCalendarIDsKey) private var storedHiddenCalendarIDs = ""
    @AppStorage(showsPastEventsKey) private var showsPastEvents = defaultShowsPastEvents
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
                getAgendaMeetings(
                    store.selectedDaysMeetings,
                    day: store.selectedDay,
                    now: context.date,
                    showsPastEvents: showsPastEvents,
                    hidesAllDay: hidesAllDay,
                    hidesDeclined: hidesDeclined,
                    hiddenCalendarIDs: decodeIDSet(storedHiddenCalendarIDs)
                ),
                now: context.date,
                limit: agendaLimit
            )
            HStack(alignment: .top, spacing: 12) {
                DatePicker(
                    "Day",
                    selection: Binding(get: { store.selectedDay ?? context.date }, set: store.select),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .fixedSize()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(formatAgendaTitle(day: store.selectedDay))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if store.selectedDay != nil {
                            Button("Today") { store.select(context.date) }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .help("Go back to today")
                        }
                        Spacer()
                        if store.isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help("Sync your calendars now")
                        }
                    }
                    .padding(.horizontal, 10)
                    if agenda.hiddenEarlierCount > 0 {
                        Text("+\(agenda.hiddenEarlierCount) earlier")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(agenda.earlier) { meeting in
                        MeetingRow(meeting: meeting)
                            .opacity(0.5)
                    }
                    if let next = agenda.next {
                        NextMeetingCard(meeting: next, now: context.date)
                    }
                    ForEach(agenda.rest) { meeting in
                        MeetingRow(meeting: meeting)
                    }
                    if agenda.hiddenCount > 0 {
                        Text("+\(agenda.hiddenCount) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if agenda.isEmpty {
                        Text(formatEmptyAgenda(day: store.selectedDay))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
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
            if MeetingsStore.shared.headsUpMeetingID == meeting.id {
                Button("Dismiss", systemImage: "bell.slash") { MeetingsStore.shared.dismissHeadsUp() }
                    .buttonStyle(.bordered)
                    .help("Hide this meeting's reminder in the closed notch")
            }
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
    @AppStorage(hidesAllDayKey) private var hidesAllDay = defaultHidesAllDay
    @AppStorage(hidesDeclinedKey) private var hidesDeclined = defaultHidesDeclined
    @AppStorage(hiddenCalendarIDsKey) private var storedHiddenCalendarIDs = ""
    @AppStorage(headsUpMinutesKey) private var headsUpMinutes = defaultHeadsUpMinutes
    @AppStorage(showsPastEventsKey) private var showsPastEvents = defaultShowsPastEvents

    var body: some View {
        Form {
            Toggle("Show past events", isOn: $showsPastEvents)
            Toggle("Hide all-day events", isOn: $hidesAllDay)
            Toggle("Hide events I declined", isOn: $hidesDeclined)
            Picker("Heads-up in the closed notch", selection: $headsUpMinutes) {
                Text("Off").tag(0)
                ForEach([1, 5, 10, 15], id: \.self) { minutes in
                    Text("\(minutes) min before").tag(minutes)
                }
            }
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

/// The left side of the meeting heads-up in the closed notch.
private struct HeadsUpTitle: View {
    let meeting: Meeting

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "calendar")
                .foregroundStyle(.orange)
            Text(meeting.title)
        }
    }
}

/// The right side of the meeting heads-up: a seconds countdown, then a pulsing camera once the meeting starts.
private struct HeadsUpCountdown: View {
    let meeting: Meeting

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if context.date >= meeting.start {
                Image(systemName: "video.fill")
                    .foregroundStyle(.green)
                    .symbolEffect(.pulse)
            } else {
                Text(formatTimer(seconds: Int(meeting.start.timeIntervalSince(context.date).rounded(.up))))
                    .monospacedDigit()
            }
        }
    }
}

/// Drops down under the heads-up when it appears and when the meeting starts, so it is hard to miss.
private struct HeadsUpAlert: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title)
                .font(.title3.bold())
                .lineLimit(1)
            Text("\(formatTimeRange(meeting)) · \(formatCountdown(now: .now, start: meeting.start))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }
}
