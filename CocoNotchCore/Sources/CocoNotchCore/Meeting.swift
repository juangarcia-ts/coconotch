import Foundation

public struct Meeting: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let calendarID: String
    public let isDeclined: Bool
    public let link: URL?

    public init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        calendarID: String = "",
        isDeclined: Bool = false,
        link: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarID = calendarID
        self.isDeclined = isDeclined
        self.link = link
    }
}

/// Finds the first Google Meet, Zoom or Teams link, checking each text in order (event URL, location, notes).
public func findMeetingLink(in texts: [String?]) -> URL? {
    let pattern =
        #/https://(meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}|([\w-]+\.)?zoom\.us/(j|my)/[^\s<>"]+|teams\.microsoft\.com/l/meetup-join/[^\s<>"]+|teams\.live\.com/meet/[^\s<>"]+)/#
        .ignoresCase()
    for text in texts.compactMap({ $0 }) {
        if let match = text.firstMatch(of: pattern) {
            return URL(string: String(match.output.0))
        }
    }
    return nil
}

/// Meetings that have not ended yet, earliest first, after the user's filters.
public func getUpcomingMeetings(
    _ meetings: [Meeting],
    now: Date,
    hidesAllDay: Bool,
    hidesDeclined: Bool,
    hiddenCalendarIDs: Set<String>
) -> [Meeting] {
    meetings
        .filter { meeting in
            meeting.end > now
                && !(hidesAllDay && meeting.isAllDay)
                && !(hidesDeclined && meeting.isDeclined)
                && !hiddenCalendarIDs.contains(meeting.calendarID)
        }
        .sorted { $0.start < $1.start }
}

public func formatCountdown(now: Date, start: Date) -> String {
    guard start > now else { return "Now" }
    // Round up, so a meeting 30 seconds away reads "in 1m" rather than "in 0m".
    let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
    return "in " + Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
}

/// Calendar identifiers are stored one per line; they never contain line breaks.
public func decodeIDSet(_ stored: String) -> Set<String> {
    Set(stored.split(separator: "\n").map(String.init))
}

public func encodeIDSet(_ ids: Set<String>) -> String {
    ids.sorted().joined(separator: "\n")
}

public func formatStartTime(_ meeting: Meeting) -> String {
    meeting.isAllDay ? "All day" : meeting.start.formatted(date: .omitted, time: .shortened)
}

public func formatTimeRange(_ meeting: Meeting) -> String {
    guard !meeting.isAllDay else { return formatStartTime(meeting) }
    return "\(formatStartTime(meeting))–\(meeting.end.formatted(date: .omitted, time: .shortened))"
}

public struct Agenda: Equatable, Sendable {
    /// Meetings that already ended, all of them, shown small above the next one.
    public let earlier: [Meeting]
    public let next: Meeting?
    public let rest: [Meeting]
    /// Upcoming meetings that did not fit, all after `rest`.
    public let hiddenCount: Int

    public var isEmpty: Bool { earlier.isEmpty && next == nil }
}

/// Splits meetings into ended ones, the featured next one, up to `limit` more, and how many of those did not fit.
public func makeAgenda(_ meetings: [Meeting], now: Date, limit: Int) -> Agenda {
    let upcoming = meetings.filter { $0.end > now }
    let rest = Array(upcoming.dropFirst().prefix(limit))
    return Agenda(
        earlier: meetings.filter { $0.end <= now },
        next: upcoming.first,
        rest: rest,
        hiddenCount: max(upcoming.count - 1 - rest.count, 0)
    )
}

/// The meetings the Meetings tab lists. `day` is nil for today, where ended meetings show only with
/// `showsPastEvents`; a picked day shows all of its meetings.
public func getAgendaMeetings(
    _ meetings: [Meeting],
    day: Date?,
    now: Date,
    showsPastEvents: Bool,
    hidesAllDay: Bool,
    hidesDeclined: Bool,
    hiddenCalendarIDs: Set<String>
) -> [Meeting] {
    getUpcomingMeetings(
        meetings,
        now: showsPastEvents || day != nil ? .distantPast : now,
        hidesAllDay: hidesAllDay,
        hidesDeclined: hidesDeclined,
        hiddenCalendarIDs: hiddenCalendarIDs
    )
}

/// The day to show for a date picked in the calendar: nil for today, so the agenda follows today past midnight.
public func getSelectedDay(picked: Date, now: Date, calendar: Calendar) -> Date? {
    calendar.isDate(picked, inSameDayAs: now) ? nil : picked
}

/// The bounds to load a day's meetings with: its start, and the next day's start.
public func getDayInterval(for date: Date, calendar: Calendar) -> DateInterval? {
    calendar.dateInterval(of: .day, for: date)
}

public func formatAgendaTitle(day: Date?) -> String {
    day?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) ?? "Today"
}

public func formatEmptyAgenda(day: Date?) -> String {
    day == nil ? "No more meetings today" : "No meetings"
}

/// The meeting to show in the closed notch: the first one that starts within `leadTime`, or started less than
/// `grace` ago, skipping all-day events and ones the user dismissed. A `leadTime` of zero turns this off.
public func getHeadsUpMeeting(
    _ upcoming: [Meeting],
    now: Date,
    leadTime: TimeInterval,
    grace: TimeInterval,
    dismissedIDs: Set<String>
) -> Meeting? {
    guard leadTime > 0 else { return nil }
    return upcoming.first { meeting in
        !meeting.isAllDay
            && !dismissedIDs.contains(meeting.id)
            && meeting.start.timeIntervalSince(now) <= leadTime
            && now.timeIntervalSince(meeting.start) < grace
            && meeting.end > now
    }
}

/// A countdown such as "9:42" or "1:05:00"; anything already reached reads "0:00".
public func formatTimer(seconds: Int) -> String {
    let seconds = max(seconds, 0)
    let (hours, minutes, remainder) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
    let tail = String(format: "%02d", remainder)
    return hours > 0 ? "\(hours):\(String(format: "%02d", minutes)):\(tail)" : "\(minutes):\(tail)"
}

/// A heads-up is urgent from the moment its meeting starts, so it beats other widgets' activities.
public func getHeadsUpPriority(start: Date, now: Date) -> ActivityPriority {
    start <= now ? .urgent : .normal
}

public struct MonthGrid: Equatable, Sendable {
    /// The first day of the month shown.
    public let month: Date
    /// One entry per grid cell, row by row: nil for the blank cells before the 1st.
    public let days: [Date?]
}

/// The month `monthOffset` months from `date`'s month, laid out from the calendar's first weekday.
public func makeMonthGrid(around date: Date, monthOffset: Int, calendar: Calendar) -> MonthGrid {
    let shifted = calendar.date(byAdding: .month, value: monthOffset, to: date) ?? date
    let start = calendar.dateInterval(of: .month, for: shifted)?.start ?? shifted
    let dayCount = calendar.range(of: .day, in: .month, for: start)?.count ?? 0
    let blankCount = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
    let days = (0..<dayCount).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    return MonthGrid(month: start, days: Array(repeating: nil, count: blankCount) + days)
}

/// One-letter weekday names, starting from the calendar's first weekday.
public func getWeekdaySymbols(calendar: Calendar) -> [String] {
    let symbols = calendar.veryShortStandaloneWeekdaySymbols
    let first = calendar.firstWeekday - 1
    return Array(symbols[first...] + symbols[..<first])
}

public enum DayMark: Sendable {
    case selected, today, plain
}

/// How a calendar cell is marked; the selected day wins over today.
public func getDayMark(_ day: Date, selection: Date, now: Date, calendar: Calendar) -> DayMark {
    if calendar.isDate(day, inSameDayAs: selection) { return .selected }
    return calendar.isDate(day, inSameDayAs: now) ? .today : .plain
}

/// What the Home card says with no meetings to show. Without calendar access an empty list would read as a free
/// day, so it points to the Meetings tab, where access is granted.
public func formatMeetingsSummaryEmpty(hasCalendarAccess: Bool) -> String {
    hasCalendarAccess ? formatEmptyAgenda(day: nil) : "Calendar access needed. Open Meetings to allow it."
}
