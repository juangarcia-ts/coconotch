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

@Test func formatsStartTime() {
    let start = Date(timeIntervalSince1970: 10_000)
    #expect(formatStartTime(Meeting(id: "a", title: "A", start: start, end: start + 3600, isAllDay: true)) == "All day")
    #expect(
        formatStartTime(Meeting(id: "b", title: "B", start: start, end: start + 3600))
            == start.formatted(date: .omitted, time: .shortened)
    )
}

@Test(arguments: [(0, false, 0, 0), (1, true, 0, 0), (4, true, 3, 0), (6, true, 3, 2)])
func splitsAgenda(count: Int, hasNext: Bool, restCount: Int, hiddenCount: Int) {
    let start = Date(timeIntervalSince1970: 10_000)
    let meetings = (0..<count).map { Meeting(id: "\($0)", title: "\($0)", start: start, end: start + 60) }
    let agenda = makeAgenda(meetings, now: start, limit: 3)
    #expect(agenda.earlier.isEmpty)
    #expect(agenda.hiddenEarlierCount == 0)
    #expect((agenda.next != nil) == hasNext)
    #expect(agenda.rest.count == restCount)
    #expect(agenda.hiddenCount == hiddenCount)
    #expect(agenda.rest.first?.id == (restCount > 0 ? "1" : nil))
}

@Test func splitsAgendaWithEndedMeetings() {
    let now = Date(timeIntervalSince1970: 100_000)
    func meeting(_ id: String, endsIn minutes: Double) -> Meeting {
        Meeting(id: id, title: id, start: now + minutes * 60 - 1800, end: now + minutes * 60)
    }
    let ended = (1...4).map { meeting("ended\($0)", endsIn: Double($0 - 10)) }

    let morning = makeAgenda(ended + [meeting("next", endsIn: 30), meeting("later", endsIn: 90)], now: now, limit: 3)
    #expect(morning.earlier.map(\.id) == ["ended3", "ended4"])
    #expect(morning.next?.id == "next")
    #expect(morning.rest.map(\.id) == ["later"])
    #expect(morning.hiddenEarlierCount == 2)
    #expect(morning.hiddenCount == 0)

    let busy = makeAgenda(ended + (1...5).map { meeting("up\($0)", endsIn: Double($0 * 60)) }, now: now, limit: 3)
    #expect(busy.earlier.map(\.id) == ["ended4"])
    #expect(busy.rest.count == 3)
    #expect(busy.hiddenEarlierCount == 3)
    #expect(busy.hiddenCount == 1)

    let pastDay = makeAgenda(ended, now: now, limit: 3)
    #expect(pastDay.next == nil)
    #expect(pastDay.earlier.count == 3)
    #expect(pastDay.earlier.map(\.id) == ["ended2", "ended3", "ended4"])
    #expect(pastDay.hiddenEarlierCount == 1)
    #expect(pastDay.hiddenCount == 0)
    #expect(!pastDay.isEmpty)
    #expect(makeAgenda([], now: now, limit: 3).isEmpty)
}

@Test(arguments: [
    (false, false, ["now", "later"]), (true, false, ["ended", "now", "later"]),
    (false, true, ["ended", "now", "later"]), (true, true, ["ended", "now", "later"]),
])
func getsAgendaMeetings(showsPastEvents: Bool, isPickedDay: Bool, expected: [String]) {
    let now = Date(timeIntervalSince1970: 100_000)
    let meetings = [
        Meeting(id: "later", title: "Later", start: now + 3600, end: now + 5400),
        Meeting(id: "ended", title: "Ended", start: now - 3600, end: now - 60),
        Meeting(id: "now", title: "Now", start: now - 600, end: now + 600),
        Meeting(id: "declined", title: "Declined", start: now - 7200, end: now - 3600, isDeclined: true),
    ]
    let agendaMeetings = getAgendaMeetings(
        meetings,
        day: isPickedDay ? now - 86_400 : nil,
        now: now,
        showsPastEvents: showsPastEvents,
        hidesAllDay: true,
        hidesDeclined: true,
        hiddenCalendarIDs: []
    )
    #expect(agendaMeetings.map(\.id) == expected)
}

@Test func selectsPickedDay() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Sao_Paulo"))
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 15)))
    let laterToday = now + 8 * 3600
    let tomorrow = now + 9 * 3600 + 60
    #expect(getSelectedDay(picked: laterToday, now: now, calendar: calendar) == nil)
    #expect(getSelectedDay(picked: tomorrow, now: now, calendar: calendar) == tomorrow)
}

@Test func getsDayInterval() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Sao_Paulo"))
    let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 15)))
    let interval = try #require(getDayInterval(for: date, calendar: calendar))
    #expect(interval.start == calendar.date(from: DateComponents(year: 2026, month: 11, day: 16)))
    #expect(interval.end == calendar.date(from: DateComponents(year: 2026, month: 11, day: 17)))
}

@Test func formatsAgendaTitles() {
    let day = Date(timeIntervalSince1970: 100_000)
    #expect(formatAgendaTitle(day: nil) == "Today")
    #expect(formatAgendaTitle(day: day) == day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
    #expect(formatEmptyAgenda(day: nil) == "No more meetings today")
    #expect(formatEmptyAgenda(day: day) == "No meetings")
}

@Test func picksHeadsUpMeeting() {
    let now = Date(timeIntervalSince1970: 100_000)
    func meeting(_ id: String, startsIn minutes: Double, allDay: Bool = false) -> Meeting {
        Meeting(id: id, title: id, start: now + minutes * 60, end: now + minutes * 60 + 3600, isAllDay: allDay)
    }
    let lead: TimeInterval = 10 * 60
    let grace: TimeInterval = 10 * 60
    func pick(_ meetings: [Meeting], dismissed: Set<String> = [], lead: TimeInterval = lead) -> String? {
        getHeadsUpMeeting(meetings, now: now, leadTime: lead, grace: grace, dismissedIDs: dismissed)?.id
    }

    #expect(pick([meeting("soon", startsIn: 9)]) == "soon")
    #expect(pick([meeting("later", startsIn: 11)]) == nil)
    #expect(pick([meeting("started", startsIn: -9)]) == "started")
    #expect(pick([meeting("long ago", startsIn: -11)]) == nil)
    #expect(pick([meeting("holiday", startsIn: 0, allDay: true), meeting("soon", startsIn: 5)]) == "soon")
    #expect(pick([meeting("soon", startsIn: 5)], dismissed: ["soon"]) == nil)
    #expect(pick([meeting("soon", startsIn: 5)], lead: 0) == nil)
}

@Test(arguments: [(582, "9:42"), (5, "0:05"), (0, "0:00"), (-30, "0:00"), (3900, "1:05:00")])
func formatsTimer(seconds: Int, expected: String) {
    #expect(formatTimer(seconds: seconds) == expected)
}

@Test(arguments: [(-1.0, ActivityPriority.urgent), (0, .urgent), (1, .normal)])
func ranksHeadsUpByStart(secondsAgo: Double, expected: ActivityPriority) {
    let now = Date(timeIntervalSince1970: 100_000)
    #expect(getHeadsUpPriority(start: now + secondsAgo, now: now) == expected)
}
