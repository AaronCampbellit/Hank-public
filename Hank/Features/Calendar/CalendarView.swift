import SwiftUI
import SwiftData

struct CalendarView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var services: AppServices
    @ObservedObject var store: CalendarStore
    @State private var selectedAgendaEvent: CalendarAgendaEvent?
    @State private var eventEditorContext: CalendarEventEditorContext?

    private let onOpenSettings: () -> Void

    init(store: CalendarStore, onOpenSettings: @escaping () -> Void = {}) {
        self.store = store
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                if let infoMessage = store.infoMessage, !infoMessage.isEmpty {
                    statusBanner(message: infoMessage, tint: HankTheme.success, background: HankTheme.successSurface)
                }

                if let errorMessage = store.errorMessage, !errorMessage.isEmpty {
                    statusBanner(message: errorMessage, tint: HankTheme.error, background: HankTheme.errorSurface)
                }

                upcomingEventsSection
                monthSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .hankNavigationChrome()
            .hankScreenBackground()
            .task(id: appState.profileLoadKey) {
                guard let profileID = appState.activeProfileID else {
                    return
                }
                await store.loadIfNeeded(profileID: profileID, modelContext: modelContext, services: services)
            }
            .task(id: store.selectedDate) {
                guard appState.activeProfileID != nil else {
                    return
                }
                await store.refreshCalendarPresentation()
            }
            .sheet(item: $selectedAgendaEvent) { event in
                CalendarEventDetailSheet(
                    event: event,
                    color: color(from: event.colorHex),
                    onEdit: {
                        selectedAgendaEvent = nil
                        eventEditorContext = .edit(event)
                    },
                    onDelete: {
                        guard let eventIdentifier = event.deviceEventIdentifier else {
                            return
                        }
                        try await store.deleteEvent(eventIdentifier: eventIdentifier)
                    }
                )
            }
            .sheet(item: $eventEditorContext) { context in
                CalendarEventEditorSheet(
                    context: context,
                    calendarOptions: store.editableCalendarOptions,
                    accentColor: color(from: store.editableCalendarOptions.first?.colorHex ?? ""),
                    onSave: { draft in
                        switch draft.mode {
                        case .create:
                            return try await store.createEvent(
                                title: draft.title,
                                startDate: draft.startDate,
                                endDate: draft.endDate,
                                isAllDay: draft.isAllDay,
                                calendarIdentifier: draft.calendarIdentifier,
                                location: draft.location,
                                notes: draft.notes
                            )
                        case .edit(let eventIdentifier):
                            return try await store.updateEvent(
                                eventIdentifier: eventIdentifier,
                                title: draft.title,
                                startDate: draft.startDate,
                                endDate: draft.endDate,
                                isAllDay: draft.isAllDay,
                                location: draft.location,
                                notes: draft.notes
                            )
                        }
                    },
                    colorProvider: color(from:)
                ) { event in
                    selectedAgendaEvent = event
                    eventEditorContext = nil
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(action: onOpenSettings) {
                        Image(systemName: "slider.horizontal.3")
                    }

                    if store.isRefreshing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Button {
                            Task {
                                await store.refreshAvailableDeviceCalendars()
                                await store.refreshCalendarPresentation()
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
        }
    }

    private func statusBanner(message: String, tint: Color, background: Color) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: HankMetrics.cornerRadius, style: .continuous)
                    .fill(background)
            )
    }

    private var upcomingEventsSection: some View {
        CalendarPanel {
            if store.agendaEvents.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(sectionTitle(for: store.selectedDate))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text("No events on this day from your added calendars.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(store.agendaEvents) { event in
                    Button {
                        selectedAgendaEvent = event
                    } label: {
                        agendaEventRow(event)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Upcoming Events")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(sectionTitle(for: store.selectedDate))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var monthSection: some View {
        CalendarPanel {
            MonthCalendarPicker(
                selectedDate: $store.selectedDate,
                dotHexes: { date in
                    store.dotHexes(for: date)
                },
                colorProvider: color(from:)
            )
            .padding(.vertical, 8)
        } header: {
            Text("Month")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
        }
    }

    private func agendaEventRow(_ event: CalendarAgendaEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(color(from: event.colorHex))
                .frame(width: 10, height: 10)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    Text(event.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if event.isEditable {
                        Text("Edit")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(HankTheme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(HankTheme.accent.opacity(0.16))
                            )
                    } else {
                        Text("Read Only")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(HankTheme.chrome)
                            )
                    }
                }

                Text(event.sourceTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(eventTimeText(event))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if !event.subtitle.isEmpty {
                    Text(event.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(.vertical, 4)
    }

    private func sectionTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func eventTimeText(_ event: CalendarAgendaEvent) -> String {
        if event.isAllDay {
            return "All Day"
        }

        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "\(formatter.string(from: event.startDate)) - \(formatter.string(from: event.endDate))"
    }

    private func color(from hex: String) -> Color {
        var value = hex
        if value.hasPrefix("#") {
            value.removeFirst()
        }

        guard let intValue = Int(value, radix: 16) else {
            return HankTheme.accent
        }

        let red = Double((intValue >> 16) & 0xFF) / 255
        let green = Double((intValue >> 8) & 0xFF) / 255
        let blue = Double(intValue & 0xFF) / 255
        return Color(red: red, green: green, blue: blue)
    }
}

private struct CalendarPanel<Header: View, Content: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let header: () -> Header

    init(
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder header: @escaping () -> Header
    ) {
        self.content = content
        self.header = header
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header()
                .frame(maxWidth: .infinity, alignment: .leading)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: HankMetrics.cornerRadius, style: .continuous)
                .fill(HankTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HankMetrics.cornerRadius, style: .continuous)
                .stroke(HankTheme.stroke, lineWidth: 1)
        )
    }
}

private enum CalendarEventEditorContext: Identifiable {
    case create(selectedDate: Date)
    case edit(CalendarAgendaEvent)

    var id: String {
        switch self {
        case .create(let selectedDate):
            return "create-\(selectedDate.timeIntervalSince1970)"
        case .edit(let event):
            return "edit-\(event.id)"
        }
    }
}

private enum CalendarEventDraftMode: Equatable {
    case create
    case edit(eventIdentifier: String)
}

private struct CalendarEventDraft {
    let mode: CalendarEventDraftMode
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let calendarIdentifier: String?
    let location: String
    let notes: String
}

private struct CalendarEventDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    let event: CalendarAgendaEvent
    let color: Color
    let onEdit: () -> Void
    let onDelete: () async throws -> Void

    @State private var isDeleting = false
    @State private var errorMessage: String?
    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Circle()
                            .fill(color)
                            .frame(width: 14, height: 14)
                            .padding(.top, 4)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(event.title)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)

                            Text(event.sourceTitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(HankTheme.surface)

                if let errorMessage, !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(HankTheme.error)
                    }
                    .listRowBackground(HankTheme.errorSurface)
                }

                Section("When") {
                    detailRow("Date", value: dateText(event.startDate))
                    detailRow("Time", value: timeText)
                }
                .listRowBackground(HankTheme.surface)

                if !event.location.isEmpty {
                    Section("Location") {
                        Text(event.location)
                            .foregroundStyle(.white)
                    }
                    .listRowBackground(HankTheme.surface)
                }

                if !event.notes.isEmpty {
                    Section("Notes") {
                        Text(event.notes)
                            .foregroundStyle(.white)
                    }
                    .listRowBackground(HankTheme.surface)
                }

                Section("Source") {
                    Text(event.isEditable ? "Device calendar event" : "Subscribed web calendar event")
                        .foregroundStyle(.white)
                    if !event.isEditable {
                        Text("Subscribed web calendar events can be viewed here, but editing stays read-only in Hank.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(HankTheme.surface)

                if event.isEditable {
                    Section {
                        Button("Edit Event") {
                            dismiss()
                            onEdit()
                        }
                        .foregroundStyle(HankTheme.accent)

                        Button("Delete Event", role: .destructive) {
                            isShowingDeleteConfirmation = true
                        }
                        .disabled(isDeleting)
                    }
                    .listRowBackground(HankTheme.surface)
                }
            }
            .navigationTitle("Event")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(HankTheme.background)
            .hankNavigationChrome()
            .hankScreenBackground()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                "Delete Event",
                isPresented: $isShowingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Event", role: .destructive) {
                    Task {
                        await deleteEvent()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This only removes this event from the device calendar.")
            }
        }
    }

    private var timeText: String {
        if event.isAllDay {
            return "All Day"
        }

        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "\(formatter.string(from: event.startDate)) - \(formatter.string(from: event.endDate))"
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(.white)
        }
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func deleteEvent() async {
        isDeleting = true
        defer { isDeleting = false }

        do {
            try await onDelete()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CalendarEventEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let context: CalendarEventEditorContext
    let calendarOptions: [CalendarEventEditorCalendarOption]
    let accentColor: Color
    let onSave: (CalendarEventDraft) async throws -> CalendarAgendaEvent
    let colorProvider: (String) -> Color
    let onComplete: (CalendarAgendaEvent) -> Void

    @State private var title: String
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var isAllDay: Bool
    @State private var calendarIdentifier: String
    @State private var location: String
    @State private var notes: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        context: CalendarEventEditorContext,
        calendarOptions: [CalendarEventEditorCalendarOption],
        accentColor: Color,
        onSave: @escaping (CalendarEventDraft) async throws -> CalendarAgendaEvent,
        colorProvider: @escaping (String) -> Color,
        onComplete: @escaping (CalendarAgendaEvent) -> Void
    ) {
        self.context = context
        self.calendarOptions = calendarOptions
        self.accentColor = accentColor
        self.onSave = onSave
        self.colorProvider = colorProvider
        self.onComplete = onComplete

        switch context {
        case .create(let selectedDate):
            let defaultStartDate = Self.defaultStartDate(for: selectedDate)
            _title = State(initialValue: "")
            _startDate = State(initialValue: defaultStartDate)
            _endDate = State(initialValue: defaultStartDate.addingTimeInterval(3600))
            _isAllDay = State(initialValue: false)
            _calendarIdentifier = State(initialValue: calendarOptions.first?.calendarIdentifier ?? "")
            _location = State(initialValue: "")
            _notes = State(initialValue: "")
        case .edit(let event):
            _title = State(initialValue: event.title)
            _startDate = State(initialValue: event.startDate)
            _endDate = State(initialValue: event.endDate)
            _isAllDay = State(initialValue: event.isAllDay)
            _calendarIdentifier = State(initialValue: event.deviceCalendarIdentifier ?? calendarOptions.first?.calendarIdentifier ?? "")
            _location = State(initialValue: event.location)
            _notes = State(initialValue: event.notes)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage, !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(HankTheme.error)
                    }
                    .listRowBackground(HankTheme.errorSurface)
                }

                Section("Details") {
                    TextField("Event Title", text: $title)

                    Toggle("All Day", isOn: $isAllDay)

                    if isAllDay {
                        DatePicker("Start", selection: $startDate, displayedComponents: .date)
                        DatePicker("End", selection: $endDate, displayedComponents: .date)
                    } else {
                        DatePicker("Start", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
                        DatePicker("End", selection: $endDate, displayedComponents: [.date, .hourAndMinute])
                    }

                    TextField("Location", text: $location)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
                .listRowBackground(HankTheme.surface)

                if case .create = context {
                    Section("Calendar") {
                        if calendarOptions.isEmpty {
                            Text("Add a device calendar in Settings before creating events.")
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Calendar", selection: $calendarIdentifier) {
                                ForEach(calendarOptions) { option in
                                    HStack(spacing: 10) {
                                        Circle()
                                            .fill(colorProvider(option.colorHex))
                                            .frame(width: 10, height: 10)
                                        Text(option.title)
                                    }
                                    .tag(option.calendarIdentifier)
                                }
                            }
                            .pickerStyle(.navigationLink)
                        }
                    }
                    .listRowBackground(HankTheme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(HankTheme.background)
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .hankNavigationChrome()
            .hankScreenBackground()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task {
                                await save()
                            }
                        }
                        .tint(accentColor)
                    }
                }
            }
            .onChange(of: isAllDay) { _, newValue in
                if newValue {
                    startDate = Calendar.current.startOfDay(for: startDate)
                    endDate = Calendar.current.startOfDay(for: endDate)
                }
            }
        }
    }

    private var titleText: String {
        switch context {
        case .create:
            return "New Event"
        case .edit:
            return "Edit Event"
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let draft = CalendarEventDraft(
                mode: draftMode,
                title: title,
                startDate: startDate,
                endDate: endDate,
                isAllDay: isAllDay,
                calendarIdentifier: draftCalendarIdentifier,
                location: location,
                notes: notes
            )
            let event = try await onSave(draft)
            onComplete(event)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var draftMode: CalendarEventDraftMode {
        switch context {
        case .create:
            return .create
        case .edit(let event):
            return .edit(eventIdentifier: event.deviceEventIdentifier ?? event.id)
        }
    }

    private var draftCalendarIdentifier: String? {
        switch context {
        case .create:
            return calendarIdentifier.isEmpty ? nil : calendarIdentifier
        case .edit:
            return nil
        }
    }

    private static func defaultStartDate(for selectedDate: Date) -> Date {
        let calendar = Calendar.current
        let selectedDayStart = calendar.startOfDay(for: selectedDate)
        if calendar.isDateInToday(selectedDate) {
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: .now)
            let roundedMinute = ((components.minute ?? 0) / 30 + 1) * 30
            let extraHour = roundedMinute >= 60 ? 1 : 0
            let minute = roundedMinute >= 60 ? 0 : roundedMinute
            return calendar.date(
                bySettingHour: min((components.hour ?? 8) + extraHour, 23),
                minute: minute,
                second: 0,
                of: .now
            ) ?? .now
        }

        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: selectedDayStart) ?? selectedDate
    }
}

private struct MonthCalendarPicker: View {
    @Binding var selectedDate: Date

    let dotHexes: (Date) -> [String]
    let colorProvider: (String) -> Color

    private let calendar = Calendar.current
    private let weekdaySymbols = Calendar.current.shortStandaloneWeekdaySymbols

    var body: some View {
        VStack(spacing: 14) {
            header

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 10) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }

                ForEach(dayCells.indices, id: \.self) { index in
                    let day = dayCells[index]
                    if let date = day {
                        dayCell(for: date)
                    } else {
                        Color.clear
                            .frame(height: 40)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Button {
                shiftMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline.weight(.semibold))
            }
            .accessibilityLabel("Previous Month")

            Spacer()

            Text(monthTitle)
                .font(.headline.weight(.semibold))

            Spacer()

            Button {
                shiftMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.headline.weight(.semibold))
            }
            .accessibilityLabel("Next Month")
        }
        .foregroundStyle(.white)
    }

    private func dayCell(for date: Date) -> some View {
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(date)
        let dots = dotHexes(date)

        return Button {
            selectedDate = date
        } label: {
            VStack(spacing: 4) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.subheadline.weight(isSelected ? .bold : .semibold))
                    .foregroundStyle(isSelected ? HankTheme.background : .white)
                    .frame(width: 30, height: 30)
                    .background(
                        Circle()
                            .fill(isSelected ? HankTheme.accent : .clear)
                    )
                    .overlay(
                        Circle()
                            .stroke(isToday && !isSelected ? HankTheme.accent : .clear, lineWidth: 1.5)
                    )

                HStack(spacing: 3) {
                    ForEach(Array(dots.prefix(3)), id: \.self) { hex in
                        Circle()
                            .fill(colorProvider(hex))
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(height: 6)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dayAccessibilityLabel(for: date))
        .accessibilityValue(dayAccessibilityValue(isSelected: isSelected, isToday: isToday, eventCount: dots.count))
    }

    private func dayAccessibilityLabel(for date: Date) -> String {
        Self.dayAccessibilityFormatter.string(from: date)
    }

    private func dayAccessibilityValue(isSelected: Bool, isToday: Bool, eventCount: Int) -> String {
        var values: [String] = []
        if isSelected {
            values.append("Selected")
        }
        if isToday {
            values.append("Today")
        }
        if eventCount == 1 {
            values.append("1 event")
        } else if eventCount > 1 {
            values.append("\(eventCount) events")
        } else {
            values.append("No events")
        }
        return values.joined(separator: ", ")
    }

    private var monthTitle: String {
        Self.monthFormatter.string(from: displayedMonth)
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        return formatter
    }()

    private static let dayAccessibilityFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }()

    private var displayedMonth: Date {
        calendar.dateInterval(of: .month, for: selectedDate)?.start ?? selectedDate
    }

    private var dayCells: [Date?] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth) else {
            return []
        }

        let firstWeekday = calendar.component(.weekday, from: monthInterval.start)
        let leadingEmptyDays = (firstWeekday - calendar.firstWeekday + 7) % 7
        let daysInMonth = calendar.range(of: .day, in: .month, for: displayedMonth)?.count ?? 0

        var cells = Array(repeating: Optional<Date>.none, count: leadingEmptyDays)
        for day in 0 ..< daysInMonth {
            let date = calendar.date(byAdding: .day, value: day, to: monthInterval.start)
            cells.append(date)
        }

        let remainder = cells.count % 7
        if remainder != 0 {
            cells.append(contentsOf: Array(repeating: Optional<Date>.none, count: 7 - remainder))
        }
        return cells
    }

    private func shiftMonth(by offset: Int) {
        guard let nextMonth = calendar.date(byAdding: .month, value: offset, to: displayedMonth) else {
            return
        }

        let desiredDay = calendar.component(.day, from: selectedDate)
        let daysInNextMonth = calendar.range(of: .day, in: .month, for: nextMonth)?.count ?? desiredDay
        let clampedDay = min(desiredDay, daysInNextMonth)
        let monthStart = calendar.dateInterval(of: .month, for: nextMonth)?.start ?? nextMonth
        selectedDate = calendar.date(byAdding: .day, value: clampedDay - 1, to: monthStart) ?? nextMonth
    }
}
