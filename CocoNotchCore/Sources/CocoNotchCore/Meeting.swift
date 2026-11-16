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
    public let next: Meeting?
    public let rest: [Meeting]
    public let hiddenCount: Int
}

/// Splits upcoming meetings into the featured next one, up to `limit` more, and how many did not fit.
public func makeAgenda(_ upcoming: [Meeting], limit: Int) -> Agenda {
    let rest = Array(upcoming.dropFirst().prefix(limit))
    return Agenda(next: upcoming.first, rest: rest, hiddenCount: max(upcoming.count - 1 - rest.count, 0))
}
