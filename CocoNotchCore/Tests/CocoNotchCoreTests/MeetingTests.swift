import CocoNotchCore
import Foundation
import Testing

@Test(
    arguments: [
        (nil, nil, "Join: https://meet.google.com/abc-defg-hij", "https://meet.google.com/abc-defg-hij"),
        (
            nil, "https://us02web.zoom.us/j/81234567890?pwd=AbC123", nil,
            "https://us02web.zoom.us/j/81234567890?pwd=AbC123"
        ),
        (
            nil, nil,
            "Microsoft Teams meeting\nJoin: <https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%7d>",
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%7d"
        ),
        (
            "https://meet.google.com/aaa-bbbb-ccc", nil, "https://zoom.us/j/999",
            "https://meet.google.com/aaa-bbbb-ccc"
        ),
    ] as [(String?, String?, String?, String)])
func findsMeetingLink(url: String?, location: String?, notes: String?, expected: String) {
    #expect(findMeetingLink(in: [url, location, notes])?.absoluteString == expected)
}

@Test func ignoresNonMeetingLinks() {
    #expect(findMeetingLink(in: ["https://docs.google.com/document/d/1", "Room 4B", nil]) == nil)
}

@Test func getsUpcomingMeetingsAfterFilters() {
    let now = Date(timeIntervalSince1970: 10_000)
    let meetings = [
        Meeting(id: "later", title: "Later", start: now + 3600, end: now + 5400),
        Meeting(id: "ended", title: "Ended", start: now - 3600, end: now - 60),
        Meeting(id: "now", title: "Now", start: now - 600, end: now + 600),
        Meeting(id: "allDay", title: "Holiday", start: now - 3600, end: now + 80_000, isAllDay: true),
        Meeting(id: "declined", title: "Declined", start: now + 60, end: now + 120, isDeclined: true),
        Meeting(id: "hidden", title: "Hidden", start: now + 60, end: now + 120, calendarID: "work"),
    ]
    let upcoming = getUpcomingMeetings(
        meetings,
        now: now,
        hidesAllDay: true,
        hidesDeclined: true,
        hiddenCalendarIDs: ["work"]
    )
    #expect(upcoming.map(\.id) == ["now", "later"])

    let unfiltered = getUpcomingMeetings(
        meetings,
        now: now,
        hidesAllDay: false,
        hidesDeclined: false,
        hiddenCalendarIDs: []
    )
    #expect(unfiltered.map(\.id) == ["allDay", "now", "declined", "hidden", "later"])
}

@Test func formatsCountdown() {
    let now = Date(timeIntervalSince1970: 10_000)
    #expect(formatCountdown(now: now, start: now - 60) == "Now")
    #expect(formatCountdown(now: now, start: now) == "Now")
    #expect(formatCountdown(now: now, start: now + 30) == "in 1m")
    #expect(formatCountdown(now: now, start: now + 12 * 60).contains("12"))
    #expect(formatCountdown(now: now, start: now + 65 * 60).contains("1"))
}

@Test func roundTripsIDSet() {
    #expect(decodeIDSet(encodeIDSet(["b", "a"])) == ["a", "b"])
    #expect(decodeIDSet("").isEmpty)
    #expect(encodeIDSet([]) == "")
}

@Test func formatsTimeRange() {
    let start = Date(timeIntervalSince1970: 10_000)
    #expect(formatTimeRange(Meeting(id: "a", title: "A", start: start, end: start + 3600, isAllDay: true)) == "All day")
    let range = formatTimeRange(Meeting(id: "b", title: "B", start: start, end: start + 3600))
    #expect(range.contains("–"))
    #expect(range.hasPrefix(start.formatted(date: .omitted, time: .shortened)))
}

@Test(arguments: [(0, false, 0, 0), (1, true, 0, 0), (4, true, 3, 0), (6, true, 3, 2)])
func splitsAgenda(count: Int, hasNext: Bool, restCount: Int, hiddenCount: Int) {
    let start = Date(timeIntervalSince1970: 10_000)
    let meetings = (0..<count).map { Meeting(id: "\($0)", title: "\($0)", start: start, end: start + 60) }
    let agenda = makeAgenda(meetings, limit: 3)
    #expect((agenda.next != nil) == hasNext)
    #expect(agenda.rest.count == restCount)
    #expect(agenda.hiddenCount == hiddenCount)
    #expect(agenda.rest.first?.id == (restCount > 0 ? "1" : nil))
}
