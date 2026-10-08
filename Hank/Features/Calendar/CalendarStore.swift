import EventKit
import Foundation
import SwiftData
import SwiftUI

enum CalendarDeviceAccessState: Equatable {
    case notDetermined
    case denied
    case restricted
    case writeOnly
    case fullAccess

    var canReadCalendars: Bool {
        switch self {
        case .fullAccess:
            true
        case .notDetermined, .denied, .restricted, .writeOnly:
            false
        }
    }
}

struct DeviceCalendarOption: Identifiable, Hashable {
    let calendarIdentifier: String
    let title: String
    let sourceTitle: String
    let detailText: String
    let colorHex: String
    let isAlreadyAdded: Bool

    var id: String { calendarIdentifier }
}

struct SavedCalendarSourceItem: Identifiable, Hashable {
    let id: UUID
    let kind: SavedCalendarSourceKind
    let title: String
    let subtitle: String
    let isEnabled: Bool
    let remoteIdentifier: String
}

struct CalendarEventEditorCalendarOption: Identifiable, Hashable {
    let calendarIdentifier: String
    let title: String
    let sourceTitle: String
    let colorHex: String

    var id: String { calendarIdentifier }
}

enum CalendarAgendaEventSource: Hashable {
    case device(eventIdentifier: String, calendarIdentifier: String)
    case web(subscriptionSourceID: UUID, eventUID: String)
}

struct CalendarAgendaEvent: Identifiable, Hashable {
    let id: String
    let source: CalendarAgendaEventSource
    let sourceTitle: String
    let title: String
    let location: String
    let notes: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let colorHex: String

    var subtitle: String { location }

    var isEditable: Bool {
        if case .device = source {
            return true
        }
        return false
    }

    var deviceEventIdentifier: String? {
        guard case .device(let eventIdentifier, _) = source else {
            return nil
        }
        return eventIdentifier
    }

    var deviceCalendarIdentifier: String? {
        guard case .device(_, let calendarIdentifier) = source else {
            return nil
        }
        return calendarIdentifier
    }
}

struct CalendarAssistantEventPayload: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let calendarTitle: String
    let location: String
    let notes: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
}

struct WebCalendarEvent: Hashable {
    let uid: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let location: String
    let recurrenceID: Date?
    let recurrenceRule: WebCalendarRecurrenceRule?
    let recurrenceDates: [Date]
    let exceptionDates: [Date]
}

struct WebCalendarFeed: Hashable {
    let title: String?
    let events: [WebCalendarEvent]
}

struct WebCalendarRecurrenceRule: Hashable {
    enum Frequency: String, Hashable {
        case daily = "DAILY"
        case weekly = "WEEKLY"
        case monthly = "MONTHLY"
        case yearly = "YEARLY"
    }

    let frequency: Frequency
    let interval: Int
    let until: Date?
    let count: Int?
    let byDays: [WebCalendarByDay]
    let byMonthDays: [Int]
    let byMonths: [Int]
}

struct WebCalendarByDay: Hashable {
    let ordinal: Int?
    let weekday: Int
}

enum WebCalendarURLNormalizer {
    static func normalize(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CalendarStoreError.invalidWebCalendarURL
        }

        let candidate: String
        if trimmed.lowercased().hasPrefix("webcal://") {
            candidate = "http://" + trimmed.dropFirst("webcal://".count)
        } else if trimmed.lowercased().hasPrefix("webcals://") {
            candidate = "https://" + trimmed.dropFirst("webcals://".count)
        } else if trimmed.contains("://") {
            candidate = trimmed
        } else {
            candidate = "https://\(trimmed)"
        }

        guard
            let url = URL(string: candidate),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            url.host != nil || url.path.hasSuffix(".ics")
        else {
            throw CalendarStoreError.invalidWebCalendarURL
        }

        return url
    }
}

enum WebCalendarICSParser {
    static func parse(data: Data) throws -> WebCalendarFeed {
        guard let string = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw CalendarStoreError.invalidWebCalendarData
        }

        let lines = unfold(string: string)
        var calendarTitle: String?
        var events: [WebCalendarEvent] = []
        var currentEvent: ParsedEvent?
        var isInsideEvent = false

        for line in lines {
            if line == "BEGIN:VEVENT" {
                isInsideEvent = true
                currentEvent = ParsedEvent()
                continue
            }

            if line == "END:VEVENT" {
                if let currentEvent, let event = currentEvent.build() {
                    events.append(event)
                }
                currentEvent = nil
                isInsideEvent = false
                continue
            }

            guard let separatorIndex = line.firstIndex(of: ":") else {
                continue
            }

            let keyPortion = String(line[..<separatorIndex])
            let value = String(line[line.index(after: separatorIndex)...])
            let components = keyPortion.split(separator: ";", omittingEmptySubsequences: false)
            guard let rawKey = components.first else {
                continue
            }

            let key = rawKey.uppercased()
            let parameters = components.dropFirst().reduce(into: [String: String]()) { result, parameter in
                let parts = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else {
                    return
                }
                result[String(parts[0]).uppercased()] = String(parts[1])
            }

            if isInsideEvent {
                currentEvent?.consume(key: key, value: value, parameters: parameters)
            } else if key == "X-WR-CALNAME" {
                calendarTitle = decodeText(value)
            }
        }

        return WebCalendarFeed(title: calendarTitle, events: events)
    }

    private static func unfold(string: String) -> [String] {
        let normalized = string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let rawLines = normalized.components(separatedBy: "\n")
        var unfolded: [String] = []

        for line in rawLines {
            if line.hasPrefix(" ") || line.hasPrefix("\t"), !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += String(line.dropFirst())
            } else {
                unfolded.append(line)
            }
        }

        return unfolded
    }

    private static func decodeText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ParsedEvent {
        var uid = UUID().uuidString
        var title = "Untitled Event"
        var location = ""
        var startDate: Date?
        var endDate: Date?
        var isAllDay = false
        var recurrenceID: Date?
        var recurrenceRule: WebCalendarRecurrenceRule?
        var recurrenceDates: [Date] = []
        var exceptionDates: [Date] = []

        mutating func consume(key: String, value: String, parameters: [String: String]) {
            switch key {
            case "UID":
                let decoded = WebCalendarICSParser.decodeText(value)
                if !decoded.isEmpty {
                    uid = decoded
                }
            case "SUMMARY":
                let decoded = WebCalendarICSParser.decodeText(value)
                if !decoded.isEmpty {
                    title = decoded
                }
            case "LOCATION":
                location = WebCalendarICSParser.decodeText(value)
            case "DTSTART":
                if let parsed = Self.parseDate(value, parameters: parameters) {
                    startDate = parsed.date
                    isAllDay = parsed.isAllDay
                }
            case "DTEND":
                if let parsed = Self.parseDate(value, parameters: parameters) {
                    endDate = parsed.date
                }
            case "RECURRENCE-ID":
                recurrenceID = Self.parseDate(value, parameters: parameters)?.date
            case "RRULE":
                recurrenceRule = Self.parseRecurrenceRule(value)
            case "RDATE":
                recurrenceDates.append(contentsOf: Self.parseDateList(value, parameters: parameters))
            case "EXDATE":
                exceptionDates.append(contentsOf: Self.parseDateList(value, parameters: parameters))
            default:
                break
            }
        }

        func build() -> WebCalendarEvent? {
            guard let startDate else {
                return nil
            }

            let resolvedEndDate: Date
            if let endDate, endDate >= startDate {
                resolvedEndDate = endDate
            } else if isAllDay {
                resolvedEndDate = Calendar.current.date(byAdding: .day, value: 1, to: startDate) ?? startDate
            } else {
                resolvedEndDate = Calendar.current.date(byAdding: .hour, value: 1, to: startDate) ?? startDate
            }

            return WebCalendarEvent(
                uid: uid,
                title: title,
                startDate: startDate,
                endDate: resolvedEndDate,
                isAllDay: isAllDay,
                location: location,
                recurrenceID: recurrenceID,
                recurrenceRule: recurrenceRule,
                recurrenceDates: recurrenceDates,
                exceptionDates: exceptionDates
            )
        }

        private static func parseDate(_ rawValue: String, parameters: [String: String]) -> (date: Date, isAllDay: Bool)? {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                return nil
            }

            if parameters["VALUE"]?.uppercased() == "DATE" || value.count == 8 {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = Calendar.current.timeZone
                formatter.dateFormat = "yyyyMMdd"
                guard let date = formatter.date(from: value) else {
                    return nil
                }
                return (date, true)
            }

            let timezone = parameters["TZID"].flatMap(TimeZone.init(identifier:))
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timezone ?? Calendar.current.timeZone

            if value.hasSuffix("Z") {
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            } else if value.count == 15 {
                formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            } else if value.count == 13 {
                formatter.dateFormat = "yyyyMMdd'T'HHmm"
            } else {
                return nil
            }

            guard let date = formatter.date(from: value) else {
                return nil
            }

            return (date, false)
        }

        private static func parseDateList(_ rawValue: String, parameters: [String: String]) -> [Date] {
            rawValue
                .split(separator: ",", omittingEmptySubsequences: true)
                .compactMap { parseDate(String($0), parameters: parameters)?.date }
        }

        private static func parseRecurrenceRule(_ rawValue: String) -> WebCalendarRecurrenceRule? {
            let parts = rawValue.split(separator: ";", omittingEmptySubsequences: true)
            var values: [String: String] = [:]
            for part in parts {
                let tokens = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard tokens.count == 2 else {
                    continue
                }
                values[String(tokens[0]).uppercased()] = String(tokens[1]).uppercased()
            }

            guard
                let frequencyRawValue = values["FREQ"],
                let frequency = WebCalendarRecurrenceRule.Frequency(rawValue: frequencyRawValue)
            else {
                return nil
            }

            let interval = max(1, Int(values["INTERVAL"] ?? "") ?? 1)
            let count = Int(values["COUNT"] ?? "")
            let until = values["UNTIL"].flatMap {
                parseDate($0, parameters: [:])?.date
            }
            let byDays = values["BYDAY"]?
                .split(separator: ",", omittingEmptySubsequences: true)
                .compactMap { parseByDay(String($0)) } ?? []
            let byMonthDays = values["BYMONTHDAY"]?
                .split(separator: ",", omittingEmptySubsequences: true)
                .compactMap { Int($0) } ?? []
            let byMonths = values["BYMONTH"]?
                .split(separator: ",", omittingEmptySubsequences: true)
                .compactMap { Int($0) } ?? []

            return WebCalendarRecurrenceRule(
                frequency: frequency,
                interval: interval,
                until: until,
                count: count,
                byDays: byDays,
                byMonthDays: byMonthDays,
                byMonths: byMonths
            )
        }

        private static func parseByDay(_ rawValue: String) -> WebCalendarByDay? {
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard trimmed.count >= 2 else {
                return nil
            }

            let weekdayToken = String(trimmed.suffix(2))
            let weekday: Int
            switch weekdayToken {
            case "SU": weekday = 1
            case "MO": weekday = 2
            case "TU": weekday = 3
            case "WE": weekday = 4
            case "TH": weekday = 5
            case "FR": weekday = 6
            case "SA": weekday = 7
            default: return nil
            }

            let ordinalToken = String(trimmed.dropLast(2))
            let ordinal = ordinalToken.isEmpty ? nil : Int(ordinalToken)
            return WebCalendarByDay(ordinal: ordinal, weekday: weekday)
        }
    }
}

enum CalendarStoreError: LocalizedError {
    case invalidWebCalendarURL
    case invalidWebCalendarData
    case duplicateSource
    case deviceCalendarUnavailable
    case noEditableCalendars
    case invalidEventTitle
    case invalidEventDates
    case eventNotFound
    case profileNotLoaded

    var errorDescription: String? {
        switch self {
        case .invalidWebCalendarURL:
            "Enter a valid web calendar URL."
        case .invalidWebCalendarData:
            "The web calendar could not be read."
        case .duplicateSource:
            "That calendar is already added."
        case .deviceCalendarUnavailable:
            "That device calendar is no longer available."
        case .noEditableCalendars:
            "Add a device calendar before creating events in Hank."
        case .invalidEventTitle:
            "Enter an event title."
        case .invalidEventDates:
            "Choose a valid start and end time for the event."
        case .eventNotFound:
            "That calendar event could not be found."
        case .profileNotLoaded:
            "Load a profile before changing calendar sources."
        }
    }
}

@MainActor
final class CalendarStore: ObservableObject {
    @Published var selectedDate = Date()
    @Published var webCalendarName = ""
    @Published var webCalendarURL = ""
    @Published private(set) var accessState: CalendarDeviceAccessState = .notDetermined
    @Published private(set) var availableDeviceCalendars: [DeviceCalendarOption] = []
    @Published private(set) var savedSources: [SavedCalendarSourceItem] = []
    @Published private(set) var agendaEvents: [CalendarAgendaEvent] = []
    @Published private(set) var monthEventDots: [Date: [String]] = [:]
    @Published private(set) var isRefreshing = false
    @Published var infoMessage: String? {
        didSet {
            scheduleBannerDismiss(for: .info, message: infoMessage)
        }
    }
    @Published var errorMessage: String? {
        didSet {
            scheduleBannerDismiss(for: .error, message: errorMessage)
        }
    }
    @Published private(set) var highlightedAssistantEventID: String?

    var editableCalendarOptions: [CalendarEventEditorCalendarOption] {
        guard accessState.canReadCalendars else {
            return []
        }

        return savedSources
            .filter { $0.isEnabled && $0.kind == .deviceCalendar }
            .compactMap { source in
                guard let calendar = eventStore.calendar(withIdentifier: source.remoteIdentifier) else {
                    return nil
                }

                return CalendarEventEditorCalendarOption(
                    calendarIdentifier: calendar.calendarIdentifier,
                    title: calendar.title,
                    sourceTitle: calendar.source.title,
                    colorHex: Self.hexColor(from: calendar.cgColor)
                )
            }
            .sorted { lhs, rhs in
                if lhs.sourceTitle == rhs.sourceTitle {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.sourceTitle.localizedCaseInsensitiveCompare(rhs.sourceTitle) == .orderedAscending
            }
    }

    var canCreateEvents: Bool {
        !editableCalendarOptions.isEmpty
    }

    private let eventStore = EKEventStore()
    private var currentProfileID: UUID?
    private var modelContext: ModelContext?
    private weak var services: AppServices?
    private var webFeedCache: [String: (fetchedAt: Date, feed: WebCalendarFeed)] = [:]
    private var infoDismissTask: Task<Void, Never>?
    private var errorDismissTask: Task<Void, Never>?
    private var isLoading = false
    private var isRefreshingPresentation = false

    deinit {
        infoDismissTask?.cancel()
        errorDismissTask?.cancel()
    }

    func loadIfNeeded(profileID: UUID, modelContext: ModelContext, services: AppServices, force: Bool = false) async {
        if !force, currentProfileID == profileID {
            return
        }
        guard !isLoading else {
            return
        }
        isLoading = true
        defer { isLoading = false }
        await load(profileID: profileID, modelContext: modelContext, services: services)
    }

    func load(profileID: UUID, modelContext: ModelContext, services: AppServices) async {
        currentProfileID = profileID
        self.modelContext = modelContext
        self.services = services
        accessState = Self.resolveAccessState()
        reloadSavedSources()
        await refreshAvailableDeviceCalendars()
        await refreshCalendarPresentation()
        await syncAssistantCalendarIndexIfPossible()
    }

    func requestDeviceCalendarAccess() async {
        errorMessage = nil

        do {
            _ = try await eventStore.requestFullAccessToEvents()
            accessState = Self.resolveAccessState()
            await refreshAvailableDeviceCalendars()
            await refreshCalendarPresentation()
            await syncAssistantCalendarIndexIfPossible()
        } catch {
            errorMessage = error.localizedDescription
            accessState = Self.resolveAccessState()
        }
    }

    func addDeviceCalendar(identifier: String) async {
        do {
            let (profileID, modelContext) = try requireLoadedContext()
            guard let calendar = eventStore.calendar(withIdentifier: identifier) else {
                throw CalendarStoreError.deviceCalendarUnavailable
            }

            let existing = try SavedCalendarSource.fetchAll(for: profileID, in: modelContext)
            if existing.contains(where: { $0.kind == .deviceCalendar && $0.remoteIdentifier == identifier }) {
                throw CalendarStoreError.duplicateSource
            }

            let source = SavedCalendarSource(profileID: profileID)
            source.applyDeviceCalendar(
                title: calendar.title,
                calendarIdentifier: calendar.calendarIdentifier,
                sourceTitle: calendar.source.title,
                detailText: Self.detailText(for: calendar),
                isEnabled: true
            )
            modelContext.insert(source)
            try modelContext.save()
            scheduleProfileMirrorSync()
            errorMessage = nil
            infoMessage = "\"\(calendar.title)\" added."
            reloadSavedSources()
            await refreshAvailableDeviceCalendars()
            await refreshCalendarPresentation()
            await syncAssistantCalendarIndexIfPossible()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addWebCalendar() async {
        do {
            let (profileID, modelContext) = try requireLoadedContext()
            let normalizedURL = try WebCalendarURLNormalizer.normalize(webCalendarURL)
            let normalizedURLString = normalizedURL.absoluteString
            let existing = try SavedCalendarSource.fetchAll(for: profileID, in: modelContext)
            if existing.contains(where: { $0.kind == .webSubscription && $0.urlString == normalizedURLString }) {
                throw CalendarStoreError.duplicateSource
            }

            let displayName = webCalendarName.trimmingCharacters(in: .whitespacesAndNewlines)
            let detailText = normalizedURL.host ?? normalizedURLString
            let source = SavedCalendarSource(profileID: profileID)
            source.applyWebSubscription(
                displayName: displayName,
                urlString: normalizedURLString,
                detailText: detailText,
                isEnabled: true
            )
            modelContext.insert(source)
            try modelContext.save()
            scheduleProfileMirrorSync()
            webCalendarName = ""
            webCalendarURL = ""
            errorMessage = nil
            infoMessage = "Web calendar added."
            reloadSavedSources()
            await refreshCalendarPresentation()
            await syncAssistantCalendarIndexIfPossible()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setSourceEnabled(_ sourceID: UUID, isEnabled: Bool) async {
        do {
            let (profileID, modelContext) = try requireLoadedContext()
            guard let source = try SavedCalendarSource.fetchAll(for: profileID, in: modelContext)
                .first(where: { $0.id == sourceID }) else {
                return
            }
            source.isEnabled = isEnabled
            source.updatedAt = .now
            try modelContext.save()
            scheduleProfileMirrorSync()
            reloadSavedSources()
            await refreshCalendarPresentation()
            await syncAssistantCalendarIndexIfPossible()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeSources(at offsets: IndexSet) async {
        do {
            let (profileID, modelContext) = try requireLoadedContext()
            let currentSources = try SavedCalendarSource.fetchAll(for: profileID, in: modelContext)
            for index in offsets {
                guard currentSources.indices.contains(index) else {
                    continue
                }
                modelContext.delete(currentSources[index])
            }
            try modelContext.save()
            scheduleProfileMirrorSync()
            reloadSavedSources()
            await refreshAvailableDeviceCalendars()
            await refreshCalendarPresentation()
            await syncAssistantCalendarIndexIfPossible()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func focus(on date: Date, highlightedEventID: String? = nil) async {
        selectedDate = date
        highlightedAssistantEventID = highlightedEventID
        await refreshCalendarPresentation()
    }

    func resetToHome() async {
        selectedDate = Date()
        highlightedAssistantEventID = nil
        errorMessage = nil
        infoMessage = nil
        await refreshCalendarPresentation()
    }

    func assistantSearchEvents(query: String, limit: Int = 10) async -> [CalendarAssistantEventPayload] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return []
        }

        let entries = await assistantIndexEntries()
        let normalizedQuery = trimmedQuery.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return entries
            .filter { entry in
                let searchableText = "\(entry.title) \(entry.calendarTitle) \(entry.location) \(entry.notes)"
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                return searchableText.contains(normalizedQuery)
            }
            .sorted {
                if $0.startDate != $1.startDate {
                    return $0.startDate < $1.startDate
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            .prefix(limit)
            .map { $0 }
    }

    func assistantCreateEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        calendarIdentifier: String? = nil,
        location: String = "",
        notes: String = ""
    ) async throws -> CalendarAssistantEventPayload {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw CalendarStoreError.invalidEventTitle
        }

        guard accessState.canReadCalendars else {
            throw CalendarStoreError.deviceCalendarUnavailable
        }

        let normalizedDates = Self.normalizedEventDates(
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay
        )

        guard let calendar = preferredCalendar(for: calendarIdentifier) else {
            throw CalendarStoreError.noEditableCalendars
        }

        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = trimmedTitle
        event.location = location.trimmingCharacters(in: .whitespacesAndNewlines)
        event.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        event.isAllDay = isAllDay
        event.startDate = normalizedDates.startDate
        event.endDate = normalizedDates.endDate
        try eventStore.save(event, span: .thisEvent, commit: true)

        let payload = CalendarAssistantEventPayload(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "Untitled Event",
            calendarTitle: calendar.title,
            location: event.location ?? "",
            notes: event.notes ?? "",
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay
        )

        selectedDate = normalizedDates.startDate
        highlightedAssistantEventID = payload.id
        await refreshCalendarPresentation()
        await syncAssistantCalendarIndexIfPossible()
        return payload
    }

    func assistantUpdateEvent(
        eventIdentifier: String,
        title: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        isAllDay: Bool? = nil,
        location: String? = nil,
        notes: String? = nil
    ) async throws -> CalendarAssistantEventPayload {
        guard let event = eventStore.event(withIdentifier: eventIdentifier) else {
            throw CalendarStoreError.eventNotFound
        }

        if let title {
            event.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let isAllDay {
            event.isAllDay = isAllDay
        }
        let normalizedDates = try Self.updatedEventDates(
            existingStartDate: event.startDate,
            existingEndDate: event.endDate,
            startDate: startDate,
            endDate: endDate,
            isAllDay: event.isAllDay
        )
        event.startDate = normalizedDates.startDate
        event.endDate = normalizedDates.endDate
        if let location {
            event.location = location.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let notes {
            event.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try eventStore.save(event, span: .thisEvent, commit: true)

        let payload = CalendarAssistantEventPayload(
            id: event.eventIdentifier ?? eventIdentifier,
            title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Untitled Event",
            calendarTitle: event.calendar.title,
            location: event.location ?? "",
            notes: event.notes ?? "",
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay
        )

        selectedDate = payload.startDate
        highlightedAssistantEventID = payload.id
        await refreshCalendarPresentation()
        await syncAssistantCalendarIndexIfPossible()
        return payload
    }

    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        calendarIdentifier: String?,
        location: String,
        notes: String
    ) async throws -> CalendarAgendaEvent {
        let payload = try await assistantCreateEvent(
            title: title,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            calendarIdentifier: calendarIdentifier,
            location: location,
            notes: notes
        )

        guard let event = eventStore.event(withIdentifier: payload.id) else {
            throw CalendarStoreError.eventNotFound
        }

        return makeDeviceAgendaEvent(
            event: event,
            sourceTitle: event.calendar.title,
            colorHex: Self.hexColor(from: event.calendar.cgColor)
        )
    }

    func updateEvent(
        eventIdentifier: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String,
        notes: String
    ) async throws -> CalendarAgendaEvent {
        let payload = try await assistantUpdateEvent(
            eventIdentifier: eventIdentifier,
            title: title,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            location: location,
            notes: notes
        )

        guard let event = eventStore.event(withIdentifier: payload.id) else {
            throw CalendarStoreError.eventNotFound
        }

        return makeDeviceAgendaEvent(
            event: event,
            sourceTitle: event.calendar.title,
            colorHex: Self.hexColor(from: event.calendar.cgColor)
        )
    }

    func deleteEvent(eventIdentifier: String) async throws {
        guard let event = eventStore.event(withIdentifier: eventIdentifier) else {
            throw CalendarStoreError.eventNotFound
        }

        try eventStore.remove(event, span: .thisEvent, commit: true)
        highlightedAssistantEventID = nil
        await refreshCalendarPresentation()
        await syncAssistantCalendarIndexIfPossible()
    }

    func assistantIndexEntries() async -> [CalendarAssistantEventPayload] {
        guard let profileID = currentProfileID, let modelContext else {
            return []
        }

        do {
            let sources = try SavedCalendarSource.fetchAll(for: profileID, in: modelContext)
            let calendar = Calendar.current
            let startDate = calendar.date(byAdding: .day, value: -90, to: calendar.startOfDay(for: .now)) ?? .now
            let endDate = calendar.date(byAdding: .day, value: 365, to: startDate) ?? startDate

            var entries: [CalendarAssistantEventPayload] = []
            if accessState.canReadCalendars {
                entries.append(contentsOf: loadDeviceIndexEntries(for: sources.filter { $0.isEnabled && $0.kind == .deviceCalendar }, startDate: startDate, endDate: endDate))
            }
            entries.append(contentsOf: await loadWebIndexEntries(for: sources.filter { $0.isEnabled && $0.kind == .webSubscription }, startDate: startDate, endDate: endDate))
            return entries.sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate {
                    return lhs.startDate < rhs.startDate
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func prepareAssistantCalendarIndex(profileID: UUID, modelContext: ModelContext, services: AppServices) async {
        currentProfileID = profileID
        self.modelContext = modelContext
        self.services = services
        accessState = Self.resolveAccessState()
        reloadSavedSources()
        await syncAssistantCalendarIndexIfPossible()
    }

    func syncAssistantCalendarIndexIfPossible() async {
        guard let services,
              let modelContext,
              let context = try? services.hankRemoteConnectionContext(in: modelContext)
        else {
            return
        }

        let entries = await assistantIndexEntries().map {
            HankRemoteAssistantCalendarIndexEntry(
                id: $0.id,
                externalEventID: $0.id,
                calendarID: $0.calendarTitle,
                calendarTitle: $0.calendarTitle,
                title: $0.title,
                location: $0.location,
                notes: $0.notes,
                startsAt: $0.startDate,
                endsAt: $0.endDate,
                isAllDay: $0.isAllDay
            )
        }

        let timezoneIdentifier = TimeZone.current.identifier
        let deviceID = Self.assistantDeviceIdentifier()

        do {
            try await services.hankRemoteService.uploadAssistantCalendarIndex(
                entries: entries,
                deviceID: deviceID,
                timezone: timezoneIdentifier,
                context: context
            )
        } catch HankRemoteServiceError.notFound {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshCalendarPresentation() async {
        guard !isRefreshingPresentation else {
            return
        }
        isRefreshingPresentation = true
        defer { isRefreshingPresentation = false }

        await refreshAgenda()
        await refreshMonthEventDots()
    }

    func refreshAgenda() async {
        guard let profileID = currentProfileID, let modelContext else {
            agendaEvents = []
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let sources = try SavedCalendarSource.fetchAll(for: profileID, in: modelContext)
            let dayStart = Calendar.current.startOfDay(for: selectedDate)
            let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            var events: [CalendarAgendaEvent] = []

            if accessState.canReadCalendars {
                let deviceSources = sources.filter { $0.isEnabled && $0.kind == .deviceCalendar }
                let deviceEvents = loadDeviceEvents(for: deviceSources, startDate: dayStart, endDate: dayEnd)
                events.append(contentsOf: deviceEvents)
            }

            let webSources = sources.filter { $0.isEnabled && $0.kind == .webSubscription }
            let webEvents = await loadWebEvents(for: webSources, startDate: dayStart, endDate: dayEnd)
            events.append(contentsOf: webEvents)

            agendaEvents = Self.uniquedFirst(
                events.sorted {
                    if $0.isAllDay != $1.isAllDay {
                        return $0.isAllDay && !$1.isAllDay
                    }
                    if $0.startDate != $1.startDate {
                        return $0.startDate < $1.startDate
                    }
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
            ) { $0.id }
        } catch {
            agendaEvents = []
            errorMessage = error.localizedDescription
        }
    }

    func refreshMonthEventDots() async {
        guard let profileID = currentProfileID, let modelContext else {
            monthEventDots = [:]
            return
        }

        do {
            let monthStart = Calendar.current.dateInterval(of: .month, for: selectedDate)?.start
                ?? Calendar.current.startOfDay(for: selectedDate)
            let monthEnd = Calendar.current.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
            let sources = try SavedCalendarSource.fetchAll(for: profileID, in: modelContext)
            var dots: [Date: [String]] = [:]

            if accessState.canReadCalendars {
                let deviceSources = sources.filter { $0.isEnabled && $0.kind == .deviceCalendar }
                let deviceEvents = loadDeviceEvents(for: deviceSources, startDate: monthStart, endDate: monthEnd)
                Self.appendDayDots(from: deviceEvents, into: &dots)
            }

            let webSources = sources.filter { $0.isEnabled && $0.kind == .webSubscription }
            let webEvents = await loadWebEvents(for: webSources, startDate: monthStart, endDate: monthEnd)
            Self.appendDayDots(from: webEvents, into: &dots)
            monthEventDots = dots
        } catch {
            monthEventDots = [:]
            errorMessage = error.localizedDescription
        }
    }

    func dotHexes(for date: Date) -> [String] {
        monthEventDots[Calendar.current.startOfDay(for: date)] ?? []
    }

    func refreshAvailableDeviceCalendars() async {
        guard accessState.canReadCalendars else {
            availableDeviceCalendars = []
            return
        }

        do {
            let (profileID, modelContext) = try requireLoadedContext()
            let savedIdentifiers = Set(
                try SavedCalendarSource.fetchAll(for: profileID, in: modelContext)
                    .filter { $0.kind == .deviceCalendar }
                    .map(\.remoteIdentifier)
            )

            let calendars = Self.uniquedFirst(
                eventStore.calendars(for: .event)
                    .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .filter { !$0.calendarIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .filter { !$0.isSubscribed }
            ) { $0.calendarIdentifier }

            availableDeviceCalendars = calendars
                .map { calendar in
                    DeviceCalendarOption(
                        calendarIdentifier: calendar.calendarIdentifier,
                        title: calendar.title,
                        sourceTitle: calendar.source.title,
                        detailText: Self.detailText(for: calendar),
                        colorHex: Self.hexColor(from: calendar.cgColor),
                        isAlreadyAdded: savedIdentifiers.contains(calendar.calendarIdentifier)
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.isAlreadyAdded != rhs.isAlreadyAdded {
                        return !lhs.isAlreadyAdded && rhs.isAlreadyAdded
                    }
                    if lhs.sourceTitle == rhs.sourceTitle {
                        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                    }
                    return lhs.sourceTitle.localizedCaseInsensitiveCompare(rhs.sourceTitle) == .orderedAscending
                }
        } catch {
            availableDeviceCalendars = []
            errorMessage = error.localizedDescription
        }
    }

    private enum BannerKind {
        case info
        case error
    }

    private func scheduleBannerDismiss(for kind: BannerKind, message: String?) {
        let task: Task<Void, Never>?

        switch kind {
        case .info:
            infoDismissTask?.cancel()
            task = message.map { message in
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    guard !Task.isCancelled else {
                        return
                    }

                    await MainActor.run {
                        if self?.infoMessage == message {
                            self?.infoMessage = nil
                        }
                    }
                }
            }
            infoDismissTask = task
        case .error:
            errorDismissTask?.cancel()
            task = message.map { message in
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    guard !Task.isCancelled else {
                        return
                    }

                    await MainActor.run {
                        if self?.errorMessage == message {
                            self?.errorMessage = nil
                        }
                    }
                }
            }
            errorDismissTask = task
        }
    }

    private func reloadSavedSources() {
        do {
            guard let profileID = currentProfileID, let modelContext else {
                savedSources = []
                return
            }

            let sources = try SavedCalendarSource.fetchAll(for: profileID, in: modelContext)
            savedSources = sources.map {
                SavedCalendarSourceItem(
                    id: $0.id,
                    kind: $0.kind,
                    title: $0.effectiveDisplayName,
                    subtitle: $0.detailText.isEmpty ? $0.sourceTitle : $0.detailText,
                    isEnabled: $0.isEnabled,
                    remoteIdentifier: $0.remoteIdentifier
                )
            }
        } catch {
            savedSources = []
            errorMessage = error.localizedDescription
        }
    }

    private func loadDeviceEvents(
        for sources: [SavedCalendarSource],
        startDate: Date,
        endDate: Date
    ) -> [CalendarAgendaEvent] {
        let calendars = Self.uniquedFirst(
            sources.compactMap { source -> (SavedCalendarSource, EKCalendar)? in
                guard let calendar = eventStore.calendar(withIdentifier: source.remoteIdentifier) else {
                    return nil
                }
                return (source, calendar)
            }
        ) { $0.1.calendarIdentifier }

        guard !calendars.isEmpty else {
            return []
        }

        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: calendars.map(\.1)
        )

        let events = eventStore.events(matching: predicate)
        let colorByIdentifier = Dictionary(uniqueKeysWithValues: calendars.map { ($0.1.calendarIdentifier, Self.hexColor(from: $0.1.cgColor)) })
        let titleByIdentifier = Dictionary(uniqueKeysWithValues: calendars.map { ($0.1.calendarIdentifier, $0.0.effectiveDisplayName) })

        return events.map { event in
            makeDeviceAgendaEvent(
                event: event,
                sourceTitle: titleByIdentifier[event.calendar.calendarIdentifier] ?? event.calendar.title,
                colorHex: colorByIdentifier[event.calendar.calendarIdentifier] ?? Self.hexColor(from: event.calendar.cgColor)
            )
        }
    }

    private func loadWebEvents(
        for sources: [SavedCalendarSource],
        startDate: Date,
        endDate: Date
    ) async -> [CalendarAgendaEvent] {
        guard !sources.isEmpty else {
            return []
        }

        var loadedEvents: [CalendarAgendaEvent] = []
        for source in sources {
            loadedEvents.append(contentsOf: await events(for: source, startDate: startDate, endDate: endDate))
        }
        return loadedEvents
    }

    private func events(
        for source: SavedCalendarSource,
        startDate: Date,
        endDate: Date
    ) async -> [CalendarAgendaEvent] {
        do {
            let feed = try await webFeed(for: source)
            let filtered = Self.expandWebEvents(feed.events, startDate: startDate, endDate: endDate)
            return filtered.map { event in
                CalendarAgendaEvent(
                    id: "web:\(source.id.uuidString):\(event.uid)",
                    source: .web(subscriptionSourceID: source.id, eventUID: event.uid),
                    sourceTitle: source.effectiveDisplayName,
                    title: event.title,
                    location: event.location,
                    notes: "",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    isAllDay: event.isAllDay,
                    colorHex: "4FBCFF"
                )
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
            }
            return []
        }
    }

    private func loadDeviceIndexEntries(
        for sources: [SavedCalendarSource],
        startDate: Date,
        endDate: Date
    ) -> [CalendarAssistantEventPayload] {
        let calendars = Self.uniquedFirst(
            sources.compactMap { source -> (SavedCalendarSource, EKCalendar)? in
                guard let calendar = eventStore.calendar(withIdentifier: source.remoteIdentifier) else {
                    return nil
                }
                return (source, calendar)
            }
        ) { $0.1.calendarIdentifier }

        guard !calendars.isEmpty else {
            return []
        }

        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: calendars.map(\.1)
        )

        let titleByIdentifier = Dictionary(uniqueKeysWithValues: calendars.map { ($0.1.calendarIdentifier, $0.0.effectiveDisplayName) })
        return eventStore.events(matching: predicate).map { event in
            CalendarAssistantEventPayload(
                id: event.eventIdentifier ?? Self.deviceAgendaEventID(for: event),
                title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Untitled Event",
                calendarTitle: titleByIdentifier[event.calendar.calendarIdentifier] ?? event.calendar.title,
                location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                notes: event.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                startDate: event.startDate,
                endDate: event.endDate,
                isAllDay: event.isAllDay
            )
        }
    }

    private func loadWebIndexEntries(
        for sources: [SavedCalendarSource],
        startDate: Date,
        endDate: Date
    ) async -> [CalendarAssistantEventPayload] {
        guard !sources.isEmpty else {
            return []
        }

        var payloads: [CalendarAssistantEventPayload] = []
        for source in sources {
            do {
                let feed = try await webFeed(for: source)
                payloads.append(contentsOf: Self.expandWebEvents(feed.events, startDate: startDate, endDate: endDate).map { event in
                    CalendarAssistantEventPayload(
                        id: "web:\(source.id.uuidString):\(event.uid)",
                        title: event.title,
                        calendarTitle: source.effectiveDisplayName,
                        location: event.location,
                        notes: "",
                        startDate: event.startDate,
                        endDate: event.endDate,
                        isAllDay: event.isAllDay
                    )
                })
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
        return payloads
    }

    private func preferredCalendar(for identifier: String?) -> EKCalendar? {
        if let identifier,
           let calendar = eventStore.calendar(withIdentifier: identifier) {
            return calendar
        }

        if let profileID = currentProfileID,
           let modelContext,
           let source = try? SavedCalendarSource.fetchAll(for: profileID, in: modelContext)
            .first(where: { $0.isEnabled && $0.kind == .deviceCalendar }),
           let calendar = eventStore.calendar(withIdentifier: source.remoteIdentifier) {
            return calendar
        }

        return eventStore.defaultCalendarForNewEvents ?? eventStore.calendars(for: .event).first
    }

    private func makeDeviceAgendaEvent(
        event: EKEvent,
        sourceTitle: String,
        colorHex: String
    ) -> CalendarAgendaEvent {
        let rawIdentifier = event.eventIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedEventIdentifier = rawIdentifier?.nilIfEmpty ?? Self.deviceAgendaEventID(for: event)

        return CalendarAgendaEvent(
            id: Self.deviceAgendaEventID(for: event),
            source: .device(
                eventIdentifier: resolvedEventIdentifier,
                calendarIdentifier: event.calendar.calendarIdentifier
            ),
            sourceTitle: sourceTitle,
            title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Untitled Event",
            location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            notes: event.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            colorHex: colorHex
        )
    }

    private nonisolated static func assistantDeviceIdentifier() -> String {
        let defaults = UserDefaults.standard
        let key = "Hank.AssistantCalendarDeviceID"
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }

        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: key)
        return value
    }

    nonisolated static func normalizedEventDates(
        startDate: Date,
        endDate: Date,
        isAllDay: Bool
    ) -> (startDate: Date, endDate: Date) {
        let calendar = Calendar.current
        if isAllDay {
            let normalizedStartDate = calendar.startOfDay(for: startDate)
            let proposedEndDate = calendar.startOfDay(for: endDate)
            let normalizedEndDate = proposedEndDate > normalizedStartDate
                ? proposedEndDate
                : calendar.date(byAdding: .day, value: 1, to: normalizedStartDate) ?? normalizedStartDate.addingTimeInterval(86_400)
            return (normalizedStartDate, normalizedEndDate)
        }

        let minimumEndDate = startDate.addingTimeInterval(60)
        return (startDate, max(endDate, minimumEndDate))
    }

    nonisolated static func updatedEventDates(
        existingStartDate: Date,
        existingEndDate: Date,
        startDate: Date?,
        endDate: Date?,
        isAllDay: Bool
    ) throws -> (startDate: Date, endDate: Date) {
        let resolvedStartDate = startDate ?? existingStartDate
        let resolvedEndDate = endDate ?? existingEndDate
        let normalizedDates = normalizedEventDates(
            startDate: resolvedStartDate,
            endDate: resolvedEndDate,
            isAllDay: isAllDay
        )
        guard normalizedDates.endDate > normalizedDates.startDate else {
            throw CalendarStoreError.invalidEventDates
        }
        return normalizedDates
    }

    private func webFeed(for source: SavedCalendarSource) async throws -> WebCalendarFeed {
        if let cached = webFeedCache[source.urlString], Date().timeIntervalSince(cached.fetchedAt) < 300 {
            return cached.feed
        }

        guard let url = URL(string: source.urlString) else {
            throw CalendarStoreError.invalidWebCalendarURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        let parsed = try WebCalendarICSParser.parse(data: data)
        webFeedCache[source.urlString] = (Date(), parsed)
        return parsed
    }

    private nonisolated static func appendDayDots(
        from events: [CalendarAgendaEvent],
        into dots: inout [Date: [String]]
    ) {
        let calendar = Calendar.current
        for event in events {
            let lastIncludedMoment = event.endDate.addingTimeInterval(-1)
            let endReference = max(event.startDate, lastIncludedMoment)
            var day = calendar.startOfDay(for: event.startDate)
            let lastDay = calendar.startOfDay(for: endReference)

            while day <= lastDay {
                var colors = dots[day] ?? []
                if !colors.contains(event.colorHex) {
                    colors.append(event.colorHex)
                    dots[day] = Array(colors.prefix(3))
                }

                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else {
                    break
                }
                day = nextDay
            }
        }
    }

    nonisolated static func expandWebEvents(
        _ events: [WebCalendarEvent],
        startDate: Date,
        endDate: Date
    ) -> [WebCalendarEvent] {
        let overrides = events.filter { $0.recurrenceID != nil }
        let overridesByUID = Dictionary(grouping: overrides, by: \.uid)
        let overrideDatesByUID = Dictionary(
            uniqueKeysWithValues: overridesByUID.map { key, value in
                (key, Set(value.compactMap(\.recurrenceID)))
            }
        )

        var expanded: [WebCalendarEvent] = []
        for event in events where event.recurrenceID == nil {
            expanded.append(
                contentsOf: expandOccurrences(
                    for: event,
                    overriddenDates: overrideDatesByUID[event.uid] ?? [],
                    startDate: startDate,
                    endDate: endDate
                )
            )
        }

        for override in overrides where override.endDate > startDate && override.startDate < endDate {
            expanded.append(override)
        }

        return expanded
    }

    private nonisolated static func expandOccurrences(
        for event: WebCalendarEvent,
        overriddenDates: Set<Date>,
        startDate: Date,
        endDate: Date
    ) -> [WebCalendarEvent] {
        guard event.recurrenceRule != nil || !event.recurrenceDates.isEmpty else {
            guard event.endDate > startDate && event.startDate < endDate else {
                return []
            }
            return [event]
        }

        let duration = event.endDate.timeIntervalSince(event.startDate)
        let generatedStarts = recurrenceStartDates(for: event, rangeEnd: endDate)
        let additionalStarts = event.recurrenceDates
        let exceptionDates = Set(event.exceptionDates)
        let uniqueStarts = Set(generatedStarts + additionalStarts)
            .subtracting(exceptionDates)
            .subtracting(overriddenDates)
            .sorted()

        return uniqueStarts.compactMap { occurrenceStart in
            let occurrenceEnd = occurrenceStart.addingTimeInterval(duration)
            guard occurrenceEnd > startDate && occurrenceStart < endDate else {
                return nil
            }

            return WebCalendarEvent(
                uid: "\(event.uid)#\(Int(occurrenceStart.timeIntervalSinceReferenceDate))",
                title: event.title,
                startDate: occurrenceStart,
                endDate: occurrenceEnd,
                isAllDay: event.isAllDay,
                location: event.location,
                recurrenceID: nil,
                recurrenceRule: nil,
                recurrenceDates: [],
                exceptionDates: []
            )
        }
    }

    private nonisolated static func recurrenceStartDates(for event: WebCalendarEvent, rangeEnd: Date) -> [Date] {
        guard let rule = event.recurrenceRule else {
            return [event.startDate]
        }

        let calendar = Calendar.current
        let scanEnd = min(rule.until ?? rangeEnd, rangeEnd)
        let anchorDay = calendar.startOfDay(for: event.startDate)
        let lastDay = calendar.startOfDay(for: scanEnd)
        guard anchorDay <= lastDay else {
            return []
        }

        var matchingDates: [Date] = []
        var cursor = anchorDay
        var emittedCount = 0
        var iterationCount = 0
        let maxIterations = 20_000

        while cursor <= lastDay && iterationCount < maxIterations {
            iterationCount += 1

            let candidate = occurrenceStart(on: cursor, from: event.startDate, isAllDay: event.isAllDay, calendar: calendar)
            if candidate >= event.startDate && matches(candidate, anchor: event.startDate, rule: rule, calendar: calendar) {
                emittedCount += 1
                matchingDates.append(candidate)
                if let count = rule.count, emittedCount >= count {
                    break
                }
            }

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: cursor) else {
                break
            }
            cursor = nextDay
        }

        return matchingDates
    }

    private nonisolated static func occurrenceStart(
        on day: Date,
        from template: Date,
        isAllDay: Bool,
        calendar: Calendar
    ) -> Date {
        guard !isAllDay else {
            return day
        }

        let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: template)
        return calendar.date(
            bySettingHour: timeComponents.hour ?? 0,
            minute: timeComponents.minute ?? 0,
            second: timeComponents.second ?? 0,
            of: day
        ) ?? day
    }

    private nonisolated static func matches(
        _ candidate: Date,
        anchor: Date,
        rule: WebCalendarRecurrenceRule,
        calendar: Calendar
    ) -> Bool {
        if let until = rule.until, candidate > until {
            return false
        }

        let candidateDay = calendar.startOfDay(for: candidate)
        let anchorDay = calendar.startOfDay(for: anchor)
        guard candidateDay >= anchorDay else {
            return false
        }

        if !rule.byMonths.isEmpty {
            let month = calendar.component(.month, from: candidate)
            guard rule.byMonths.contains(month) else {
                return false
            }
        }

        switch rule.frequency {
        case .daily:
            let days = calendar.dateComponents([.day], from: anchorDay, to: candidateDay).day ?? 0
            guard days % rule.interval == 0 else {
                return false
            }
            return matchesByDayIfNeeded(candidate, byDays: rule.byDays, calendar: calendar)

        case .weekly:
            let anchorWeek = calendar.dateInterval(of: .weekOfYear, for: anchorDay)?.start ?? anchorDay
            let candidateWeek = calendar.dateInterval(of: .weekOfYear, for: candidateDay)?.start ?? candidateDay
            let weeks = calendar.dateComponents([.weekOfYear], from: anchorWeek, to: candidateWeek).weekOfYear ?? 0
            guard weeks % rule.interval == 0 else {
                return false
            }
            if rule.byDays.isEmpty {
                return calendar.component(.weekday, from: candidate) == calendar.component(.weekday, from: anchor)
            }
            return matchesByDayIfNeeded(candidate, byDays: rule.byDays, calendar: calendar)

        case .monthly:
            let months = calendar.dateComponents([.month], from: anchorDay, to: candidateDay).month ?? 0
            guard months % rule.interval == 0 else {
                return false
            }
            if !rule.byMonthDays.isEmpty {
                return matchesMonthDay(candidate, byMonthDays: rule.byMonthDays, calendar: calendar)
            }
            if !rule.byDays.isEmpty {
                return matchesByDayIfNeeded(candidate, byDays: rule.byDays, calendar: calendar)
            }
            return calendar.component(.day, from: candidate) == calendar.component(.day, from: anchor)

        case .yearly:
            let years = calendar.dateComponents([.year], from: anchorDay, to: candidateDay).year ?? 0
            guard years % rule.interval == 0 else {
                return false
            }
            if rule.byMonths.isEmpty && calendar.component(.month, from: candidate) != calendar.component(.month, from: anchor) {
                return false
            }
            if !rule.byMonthDays.isEmpty {
                return matchesMonthDay(candidate, byMonthDays: rule.byMonthDays, calendar: calendar)
            }
            if !rule.byDays.isEmpty {
                return matchesByDayIfNeeded(candidate, byDays: rule.byDays, calendar: calendar)
            }
            return calendar.component(.day, from: candidate) == calendar.component(.day, from: anchor)
        }
    }

    private nonisolated static func matchesByDayIfNeeded(
        _ candidate: Date,
        byDays: [WebCalendarByDay],
        calendar: Calendar
    ) -> Bool {
        guard !byDays.isEmpty else {
            return true
        }

        return byDays.contains { byDay in
            let weekday = calendar.component(.weekday, from: candidate)
            guard weekday == byDay.weekday else {
                return false
            }

            guard let ordinal = byDay.ordinal else {
                return true
            }

            return matchesOrdinalWeekday(candidate, ordinal: ordinal, weekday: weekday, calendar: calendar)
        }
    }

    private nonisolated static func matchesMonthDay(
        _ candidate: Date,
        byMonthDays: [Int],
        calendar: Calendar
    ) -> Bool {
        let day = calendar.component(.day, from: candidate)
        let dayRange = calendar.range(of: .day, in: .month, for: candidate) ?? 1..<32
        let lastDay = dayRange.upperBound - 1

        return byMonthDays.contains { monthDay in
            if monthDay > 0 {
                return day == monthDay
            }
            let resolvedDay = lastDay + monthDay + 1
            return day == resolvedDay
        }
    }

    private nonisolated static func matchesOrdinalWeekday(
        _ candidate: Date,
        ordinal: Int,
        weekday: Int,
        calendar: Calendar
    ) -> Bool {
        guard ordinal != 0 else {
            return false
        }

        let day = calendar.component(.day, from: candidate)
        let dayRange = calendar.range(of: .day, in: .month, for: candidate) ?? 1..<32
        let lastDay = dayRange.upperBound - 1

        if ordinal > 0 {
            var occurrence = 0
            for value in dayRange {
                guard let date = calendar.date(bySetting: .day, value: value, of: candidate) else {
                    continue
                }
                if calendar.component(.weekday, from: date) == weekday {
                    occurrence += 1
                    if value == day {
                        return occurrence == ordinal
                    }
                }
            }
            return false
        } else {
            var occurrence = 0
            var value = lastDay
            while value >= dayRange.lowerBound {
                guard let date = calendar.date(bySetting: .day, value: value, of: candidate) else {
                    value -= 1
                    continue
                }
                if calendar.component(.weekday, from: date) == weekday {
                    occurrence -= 1
                    if value == day {
                        return occurrence == ordinal
                    }
                }
                value -= 1
            }
            return false
        }
    }

    private func requireLoadedContext() throws -> (UUID, ModelContext) {
        guard let profileID = currentProfileID, let modelContext else {
            throw CalendarStoreError.profileNotLoaded
        }
        return (profileID, modelContext)
    }

    private func scheduleProfileMirrorSync() {
        guard let currentProfileID, let modelContext, let services else {
            return
        }
        Task { @MainActor in
            try? await services.profileSyncCoordinator.pushExplicitProfileSnapshot(
                profileID: currentProfileID,
                modelContext: modelContext,
                services: services
            )
        }
    }

    nonisolated static func uniquedFirst<Value, Key: Hashable>(
        _ values: [Value],
        key: (Value) -> Key
    ) -> [Value] {
        var seenKeys: Set<Key> = []
        var uniqued: [Value] = []
        uniqued.reserveCapacity(values.count)

        for value in values {
            let valueKey = key(value)
            if seenKeys.insert(valueKey).inserted {
                uniqued.append(value)
            }
        }

        return uniqued
    }

    private static func resolveAccessState() -> CalendarDeviceAccessState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            .notDetermined
        case .restricted:
            .restricted
        case .denied:
            .denied
        case .writeOnly:
            .writeOnly
        case .fullAccess:
            .fullAccess
        case .authorized:
            .fullAccess
        @unknown default:
            .denied
        }
    }

    private static func detailText(for calendar: EKCalendar) -> String {
        if calendar.isSubscribed {
            return "Subscribed Web Calendar • \(calendar.source.title)"
        }

        switch calendar.type {
        case .calDAV:
            return "iCloud / CalDAV • \(calendar.source.title)"
        case .exchange:
            return "Exchange • \(calendar.source.title)"
        case .birthday:
            return "Birthdays"
        case .local:
            return "On Device"
        case .subscription:
            return "Subscribed Web Calendar • \(calendar.source.title)"
        @unknown default:
            return calendar.source.title
        }
    }

    private static func deviceAgendaEventID(for event: EKEvent) -> String {
        let baseIdentifier = event.eventIdentifier ?? event.calendarItemIdentifier
        let trimmedBaseIdentifier = baseIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedIdentifier = trimmedBaseIdentifier.isEmpty ? UUID().uuidString : trimmedBaseIdentifier
        return [
            "device",
            event.calendar.calendarIdentifier,
            resolvedIdentifier,
            String(event.startDate.timeIntervalSince1970),
            String(event.endDate.timeIntervalSince1970)
        ].joined(separator: ":")
    }

    static func hexColor(from cgColor: CGColor?) -> String {
        guard
            let components = cgColor?.components,
            !components.isEmpty
        else {
            return "6BB5FF"
        }

        let resolved: (CGFloat, CGFloat, CGFloat)
        switch components.count {
        case 1:
            resolved = (components[0], components[0], components[0])
        default:
            resolved = (components[0], components[1], components[2])
        }

        let red = Int(max(0, min(1, resolved.0)) * 255)
        let green = Int(max(0, min(1, resolved.1)) * 255)
        let blue = Int(max(0, min(1, resolved.2)) * 255)
        return String(format: "%02X%02X%02X", red, green, blue)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
