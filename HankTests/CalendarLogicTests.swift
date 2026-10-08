import XCTest
@testable import Hank

final class CalendarLogicTests: XCTestCase {
    func testCalendarAgendaEventMarksDeviceEventsEditable() {
        let event = CalendarAgendaEvent(
            id: "device:1",
            source: .device(eventIdentifier: "event-1", calendarIdentifier: "calendar-1"),
            sourceTitle: "Family",
            title: "Dinner",
            location: "Kitchen",
            notes: "Bring dessert",
            startDate: Date(timeIntervalSince1970: 100),
            endDate: Date(timeIntervalSince1970: 200),
            isAllDay: false,
            colorHex: "FF0000"
        )

        XCTAssertTrue(event.isEditable)
        XCTAssertEqual(event.deviceEventIdentifier, "event-1")
        XCTAssertEqual(event.deviceCalendarIdentifier, "calendar-1")
        XCTAssertEqual(event.subtitle, "Kitchen")
    }

    func testCalendarAgendaEventMarksWebEventsReadOnly() {
        let event = CalendarAgendaEvent(
            id: "web:1",
            source: .web(subscriptionSourceID: UUID(), eventUID: "uid-1"),
            sourceTitle: "Subscribed Feed",
            title: "Standup",
            location: "Zoom",
            notes: "",
            startDate: Date(timeIntervalSince1970: 100),
            endDate: Date(timeIntervalSince1970: 200),
            isAllDay: false,
            colorHex: "00AAFF"
        )

        XCTAssertFalse(event.isEditable)
        XCTAssertNil(event.deviceEventIdentifier)
        XCTAssertNil(event.deviceCalendarIdentifier)
    }

    func testUniquedFirstKeepsFirstOccurrenceForEachKey() {
        struct SampleValue: Equatable {
            let id: String
            let title: String
        }

        let values = [
            SampleValue(id: "work", title: "Work Primary"),
            SampleValue(id: "home", title: "Home"),
            SampleValue(id: "work", title: "Work Duplicate"),
            SampleValue(id: "travel", title: "Travel"),
            SampleValue(id: "home", title: "Home Duplicate")
        ]

        let uniqued = CalendarStore.uniquedFirst(values) { $0.id }

        XCTAssertEqual(
            uniqued,
            [
                SampleValue(id: "work", title: "Work Primary"),
                SampleValue(id: "home", title: "Home"),
                SampleValue(id: "travel", title: "Travel")
            ]
        )
    }

    func testWebCalendarURLNormalizerMapsWebcalToHTTP() throws {
        let url = try WebCalendarURLNormalizer.normalize("webcal://calendar.example.com/feed.ics")

        XCTAssertEqual(url.absoluteString, "http://calendar.example.com/feed.ics")
    }

    func testWebCalendarICSParserParsesTimedAndAllDayEvents() throws {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        X-WR-CALNAME:Family Calendar
        BEGIN:VEVENT
        UID:event-1
        SUMMARY:Dentist Appointment
        DTSTART:20260418T153000Z
        DTEND:20260418T163000Z
        LOCATION:Main Office
        END:VEVENT
        BEGIN:VEVENT
        UID:event-2
        SUMMARY:Birthday Party
        DTSTART;VALUE=DATE:20260419
        DTEND;VALUE=DATE:20260420
        END:VEVENT
        END:VCALENDAR
        """

        let feed = try WebCalendarICSParser.parse(data: Data(ics.utf8))

        XCTAssertEqual(feed.title, "Family Calendar")
        XCTAssertEqual(feed.events.count, 2)
        XCTAssertEqual(feed.events[0].title, "Dentist Appointment")
        XCTAssertEqual(feed.events[0].location, "Main Office")
        XCTAssertFalse(feed.events[0].isAllDay)
        XCTAssertEqual(feed.events[1].title, "Birthday Party")
        XCTAssertTrue(feed.events[1].isAllDay)
    }

    func testExpandWebEventsExpandsRecurringEventsAndOverrides() throws {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        UID:series-1
        SUMMARY:Standup
        DTSTART:20260418T150000Z
        DTEND:20260418T153000Z
        RRULE:FREQ=DAILY;COUNT=3
        EXDATE:20260419T150000Z
        END:VEVENT
        BEGIN:VEVENT
        UID:series-1
        SUMMARY:Moved Standup
        DTSTART:20260419T170000Z
        DTEND:20260419T173000Z
        RECURRENCE-ID:20260419T150000Z
        END:VEVENT
        END:VCALENDAR
        """

        let feed = try WebCalendarICSParser.parse(data: Data(ics.utf8))
        let dayOne = CalendarStore.expandWebEvents(
            feed.events,
            startDate: ISO8601DateFormatter().date(from: "2026-04-18T00:00:00Z")!,
            endDate: ISO8601DateFormatter().date(from: "2026-04-19T00:00:00Z")!
        )
        let dayTwo = CalendarStore.expandWebEvents(
            feed.events,
            startDate: ISO8601DateFormatter().date(from: "2026-04-19T00:00:00Z")!,
            endDate: ISO8601DateFormatter().date(from: "2026-04-20T00:00:00Z")!
        )
        let dayThree = CalendarStore.expandWebEvents(
            feed.events,
            startDate: ISO8601DateFormatter().date(from: "2026-04-20T00:00:00Z")!,
            endDate: ISO8601DateFormatter().date(from: "2026-04-21T00:00:00Z")!
        )

        XCTAssertEqual(dayOne.map(\.title), ["Standup"])
        XCTAssertEqual(dayTwo.map(\.title), ["Moved Standup"])
        XCTAssertEqual(dayThree.map(\.title), ["Standup"])
    }

    func testNormalizedEventDatesRoundsAllDayEventsToDayBoundaries() {
        let calendar = Calendar(identifier: .gregorian)
        let startDate = calendar.date(from: DateComponents(year: 2026, month: 4, day: 20, hour: 15, minute: 45))!
        let endDate = calendar.date(from: DateComponents(year: 2026, month: 4, day: 20, hour: 16, minute: 15))!

        let normalized = CalendarStore.normalizedEventDates(
            startDate: startDate,
            endDate: endDate,
            isAllDay: true
        )

        XCTAssertEqual(normalized.startDate, calendar.startOfDay(for: startDate))
        XCTAssertEqual(normalized.endDate, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: startDate)))
    }

    func testUpdatedEventDatesEnsuresTimedEventsKeepMinimumDuration() throws {
        let startDate = Date(timeIntervalSince1970: 1_000)
        let endDate = Date(timeIntervalSince1970: 1_005)

        let normalized = try CalendarStore.updatedEventDates(
            existingStartDate: startDate,
            existingEndDate: endDate,
            startDate: startDate,
            endDate: endDate,
            isAllDay: false
        )

        XCTAssertEqual(normalized.startDate, startDate)
        XCTAssertEqual(normalized.endDate, startDate.addingTimeInterval(60))
    }
}
