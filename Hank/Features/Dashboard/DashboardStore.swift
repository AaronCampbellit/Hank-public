import Foundation
import SwiftData

struct DashboardTileModel: Identifiable {
    let shortcut: DashboardShortcut
    let entity: HAEntitySummary
    let state: HAEntityState?

    var id: String { shortcut.entityID }

    var title: String {
        if let label = shortcut.labelOverride, !label.isEmpty {
            return label
        }

        return state?.friendlyName ?? entity.friendlyName
    }

    var subtitle: String {
        if isReadOnly {
            if let deviceClass = entity.deviceClass ?? state?.deviceClass, !deviceClass.isEmpty {
                return Self.humanized(deviceClass)
            }
            return "Sensor"
        }

        var components = [formattedState]
        if supportsBrightness, let brightnessPercent {
            components.append("\(brightnessPercent)%")
        }
        return components.joined(separator: " · ")
    }

    var tileSize: DashboardTileSize {
        shortcut.tileSize
    }

    var gridRow: Int {
        shortcut.gridRow
    }

    var gridColumn: Int {
        shortcut.gridColumn
    }

    var isReadOnly: Bool {
        entity.isReadOnly
    }

    var canPerformPrimaryAction: Bool {
        !isReadOnly
    }

    var supportsBrightness: Bool {
        entity.supportsBrightness && entity.domain == "light"
    }

    var brightnessPercent: Int? {
        state?.brightnessPercent
    }

    var readoutValue: String? {
        guard isReadOnly else {
            return nil
        }

        guard let rawState = state?.state, !rawState.isEmpty else {
            return nil
        }

        if Self.isNumeric(rawState) {
            return rawState
        }

        return Self.humanized(rawState)
    }

    var readoutUnit: String? {
        guard
            isReadOnly,
            let rawState = state?.state,
            Self.isNumeric(rawState),
            let unit = entity.unitOfMeasurement ?? state?.unitOfMeasurement,
            !unit.isEmpty
        else {
            return nil
        }

        return unit
    }

    private var formattedState: String {
        guard let rawState = state?.state, !rawState.isEmpty else {
            return "Unavailable"
        }

        return Self.humanized(rawState)
    }

    private static func isNumeric(_ value: String) -> Bool {
        Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    private static func humanized(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

enum DashboardGridSlot: Identifiable {
    case tile(DashboardTileModel)
    case empty(row: Int, column: Int)

    var id: String {
        switch self {
        case .tile(let tile):
            return tile.id
        case .empty(let row, let column):
            return "empty-\(row)-\(column)"
        }
    }
}

struct DashboardGridRow: Identifiable {
    let row: Int
    let fullWidthTile: DashboardTileModel?
    let leading: DashboardGridSlot?
    let trailing: DashboardGridSlot?

    var id: Int { row }
}

@MainActor
final class DashboardStore: ObservableObject {
    enum ConnectionState: Equatable {
        case needsSetup
        case loading
        case connected
        case failed(String)
    }

    @Published private(set) var connectionState: ConnectionState = .loading
    @Published private(set) var tiles: [DashboardTileModel] = []
    @Published private(set) var availableEntities: [HAEntitySummary] = []
    @Published var pickerSearchText = ""
    @Published var isShowingEntityPicker = false
    @Published var isEditing = false
    @Published var isPerformingAction = false
    @Published var errorMessage: String?

    private var stateByID: [String: HAEntityState] = [:]
    private var entityByID: [String: HAEntitySummary] = [:]
    private var shortcuts: [DashboardShortcut] = []
    private var listenTask: Task<Void, Never>?
    private var currentProfileID: UUID?
    private weak var services: AppServices?

    func loadIfNeeded(profileID: UUID, modelContext: ModelContext, services: AppServices, force: Bool = false) async {
        if !force, currentProfileID == profileID, connectionState != .loading {
            return
        }
        if currentProfileID == profileID, connectionState == .loading {
            return
        }
        await load(profileID: profileID, modelContext: modelContext, services: services)
    }

    func load(profileID: UUID, modelContext: ModelContext, services: AppServices) async {
        currentProfileID = profileID
        self.services = services

        do {
            guard let endpoint = try await services.preferredHomeAssistantEndpoint(for: profileID, in: modelContext) else {
                connectionState = .needsSetup
                tiles = []
                availableEntities = []
                errorMessage = nil
                return
            }
            let remoteContext = endpoint.remoteAccess

            connectionState = .loading
            let states = try await services.homeAssistantService.fetchStates(context: remoteContext)
            let entities = try await services.homeAssistantService.fetchEntityCatalog(context: remoteContext)

            shortcuts = try DashboardShortcut.fetchOrdered(for: profileID, in: modelContext)
            stateByID = Self.dictionaryKeepingFirstValue(states) { $0.entityID }
            entityByID = Self.dictionaryKeepingFirstValue(entities) { $0.entityID }
            applyStateMetadata(refreshedStates: states)
            rebuildTiles()
            errorMessage = nil
            connectionState = .connected
            startListening(
                context: remoteContext,
                services: services
            )
        } catch {
            connectionState = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func refresh(profileID: UUID, modelContext: ModelContext, services: AppServices) async {
        stopListening()
        await load(profileID: profileID, modelContext: modelContext, services: services)
    }

    func resumeListeningIfNeeded(profileID: UUID, modelContext: ModelContext, services: AppServices) async {
        guard currentProfileID == profileID, connectionState == .connected else {
            await loadIfNeeded(profileID: profileID, modelContext: modelContext, services: services)
            return
        }

        guard listenTask == nil else {
            return
        }

        do {
            guard let endpoint = try await services.preferredHomeAssistantEndpoint(for: profileID, in: modelContext) else {
                connectionState = .needsSetup
                errorMessage = nil
                return
            }
            startListening(context: endpoint.remoteAccess, services: services)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func presentAssistantEntity(entityID: String) {
        let trimmedEntityID = entityID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEntityID.isEmpty else {
            return
        }

        pickerSearchText = trimmedEntityID
        isShowingEntityPicker = true
    }

    func addEntity(_ entity: HAEntitySummary, profileID: UUID, modelContext: ModelContext) {
        guard !shortcuts.contains(where: { $0.entityID == entity.entityID }) else {
            return
        }

        let position = firstAvailableSlot(for: .compact, among: shortcuts)
        let shortcut = DashboardShortcut(
            profileID: profileID,
            entityID: entity.entityID,
            sortOrder: shortcuts.count,
            gridRow: position.row,
            gridColumn: position.column
        )
        modelContext.insert(shortcut)
        shortcuts.append(shortcut)
        normalizeSortOrder()
        save(modelContext)
        rebuildTiles()
    }

    func toggleEntitySelection(_ entity: HAEntitySummary, profileID: UUID, modelContext: ModelContext) {
        if let shortcut = shortcuts.first(where: { $0.entityID == entity.entityID }) {
            removeShortcut(shortcutID: shortcut.id, modelContext: modelContext)
        } else {
            addEntity(entity, profileID: profileID, modelContext: modelContext)
        }
    }

    func setEditing(_ isEditing: Bool) {
        self.isEditing = isEditing
        if !isEditing {
            isShowingEntityPicker = false
        }
    }

    func saveTileEdits(shortcutID: UUID, label: String, modelContext: ModelContext) {
        guard let shortcut = shortcuts.first(where: { $0.id == shortcutID }) else {
            return
        }

        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        shortcut.labelOverride = trimmedLabel.isEmpty ? nil : trimmedLabel
        save(modelContext)
        rebuildTiles()
    }

    func setTileSize(shortcutID: UUID, to tileSize: DashboardTileSize, modelContext: ModelContext) {
        guard let shortcut = shortcuts.first(where: { $0.id == shortcutID }) else {
            return
        }

        guard shortcut.tileSize != tileSize else {
            return
        }

        shortcut.tileSize = tileSize
        relocate(shortcut: shortcut, toRow: shortcut.gridRow, column: shortcut.gridColumn, modelContext: modelContext)
    }

    func removeShortcut(shortcutID: UUID, modelContext: ModelContext) {
        guard let shortcut = shortcuts.first(where: { $0.id == shortcutID }) else {
            return
        }

        modelContext.delete(shortcut)
        shortcuts.removeAll { $0.id == shortcutID }
        normalizeSortOrder()
        save(modelContext)
        rebuildTiles()
    }

    func moveTile(entityID: String, toRow row: Int, column: Int, modelContext: ModelContext) {
        guard let shortcut = shortcuts.first(where: { $0.entityID == entityID }) else {
            return
        }

        relocate(shortcut: shortcut, toRow: row, column: column, modelContext: modelContext)
    }

    func performPrimaryAction(_ tile: DashboardTileModel, profileID: UUID, modelContext: ModelContext, services: AppServices) async {
        guard tile.canPerformPrimaryAction else {
            return
        }

        do {
            guard let endpoint = try await services.preferredHomeAssistantEndpoint(for: profileID, in: modelContext) else {
                connectionState = .needsSetup
                return
            }
            let remoteContext = endpoint.remoteAccess

            isPerformingAction = true
            try await services.homeAssistantService.performAction(
                for: tile.entity,
                state: tile.state,
                context: remoteContext
            )
            let refreshedStates = try await services.homeAssistantService.fetchStates(context: remoteContext)
            stateByID = Self.dictionaryKeepingFirstValue(refreshedStates) { $0.entityID }
            applyStateMetadata(refreshedStates: refreshedStates)
            rebuildTiles()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }

        isPerformingAction = false
    }

    func setBrightness(
        _ brightnessPercent: Int,
        for tile: DashboardTileModel,
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices
    ) async {
        guard tile.supportsBrightness else {
            return
        }

        do {
            guard let endpoint = try await services.preferredHomeAssistantEndpoint(for: profileID, in: modelContext) else {
                connectionState = .needsSetup
                return
            }
            let remoteContext = endpoint.remoteAccess

            isPerformingAction = true
            try await services.homeAssistantService.setBrightness(
                for: tile.entity,
                brightnessPercent: brightnessPercent,
                context: remoteContext
            )
            let refreshedStates = try await services.homeAssistantService.fetchStates(context: remoteContext)
            stateByID = Self.dictionaryKeepingFirstValue(refreshedStates) { $0.entityID }
            applyStateMetadata(refreshedStates: refreshedStates)
            rebuildTiles()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }

        isPerformingAction = false
    }

    func stopListening() {
        listenTask?.cancel()
        listenTask = nil
    }

    var canEditDashboard: Bool {
        connectionState == .connected
    }

    var filteredEntities: [HAEntitySummary] {
        let query = pickerSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return availableEntities
        }

        return availableEntities
            .compactMap { entity -> (entity: HAEntitySummary, score: Int)? in
                guard let score = Self.entitySearchScore(for: entity, query: query) else {
                    return nil
                }
                return (entity, score)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                return lhs.entity.suggestedLabel.localizedCaseInsensitiveCompare(rhs.entity.suggestedLabel) == .orderedAscending
            }
            .map(\.entity)
    }

    nonisolated static func entitySearchScore(for entity: HAEntitySummary, query: String) -> Int? {
        let queryTokens = searchTokens(for: query)
        guard !queryTokens.isEmpty else {
            return nil
        }

        let searchableFields = [
            entity.friendlyName,
            entity.entityID.replacingOccurrences(of: ".", with: " "),
            entity.domain,
            entity.deviceClass ?? "",
            entity.icon ?? ""
        ]
        let searchableText = searchableFields.joined(separator: " ")
        let searchableTokens = searchTokens(for: searchableText)
        guard !searchableTokens.isEmpty else {
            return nil
        }

        let normalizedText = searchableTokens.joined(separator: " ")
        var score = 0

        for queryToken in queryTokens {
            if searchableTokens.contains(queryToken) {
                score += 12
                continue
            }

            if let singular = singularSearchToken(queryToken), searchableTokens.contains(singular) {
                score += 10
                continue
            }

            if searchableTokens.contains(where: { token in
                token.hasPrefix(queryToken) ||
                queryToken.hasPrefix(token) ||
                (singularSearchToken(token) == queryToken) ||
                (singularSearchToken(queryToken) == token)
            }) {
                score += 7
                continue
            }

            if normalizedText.contains(queryToken) {
                score += 3
                continue
            }

            return nil
        }

        if entity.friendlyName.localizedCaseInsensitiveContains(query) {
            score += 4
        }
        if entity.entityID.localizedCaseInsensitiveContains(query) {
            score += 3
        }

        return score
    }

    nonisolated static func entitySummary(from state: HAEntityState) -> HAEntitySummary? {
        guard HomeAssistantActionResolver.supports(entityID: state.entityID) else {
            return nil
        }

        let domain = state.entityID.split(separator: ".").first.map(String.init) ?? ""
        let friendlyName = state.friendlyName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? state.entityID
        return HAEntitySummary(
            entityID: state.entityID,
            friendlyName: friendlyName.isEmpty ? state.entityID : friendlyName,
            domain: domain,
            icon: state.icon,
            controlStyle: HomeAssistantActionResolver.controlStyle(for: domain),
            unitOfMeasurement: state.unitOfMeasurement,
            deviceClass: state.deviceClass,
            supportsBrightness: state.supportsBrightness
        )
    }

    var gridRows: [DashboardGridRow] {
        let byPosition = Self.dictionaryKeepingFirstValue(tiles) { GridKey(row: $0.gridRow, column: $0.gridColumn) }
        let highestRow = max(tiles.map(\.gridRow).max() ?? 0, isEditing ? (tiles.map(\.gridRow).max() ?? -1) + 2 : 0)
        guard !tiles.isEmpty || isEditing else {
            return []
        }

        return (0 ... max(highestRow, 0)).map { row in
            if let fullWidthTile = byPosition[GridKey(row: row, column: 0)], fullWidthTile.tileSize == .expanded {
                return DashboardGridRow(row: row, fullWidthTile: fullWidthTile, leading: nil, trailing: nil)
            }

            let leading: DashboardGridSlot = byPosition[GridKey(row: row, column: 0)].map(DashboardGridSlot.tile) ?? .empty(row: row, column: 0)
            let trailing: DashboardGridSlot = byPosition[GridKey(row: row, column: 1)].map(DashboardGridSlot.tile) ?? .empty(row: row, column: 1)
            return DashboardGridRow(row: row, fullWidthTile: nil, leading: leading, trailing: trailing)
        }
    }

    func isSelected(entityID: String) -> Bool {
        shortcuts.contains(where: { $0.entityID == entityID })
    }

    func primeForTesting(
        shortcuts: [DashboardShortcut],
        entities: [HAEntitySummary],
        states: [HAEntityState] = []
    ) {
        connectionState = .connected
        self.shortcuts = sort(shortcuts)
        entityByID = Self.dictionaryKeepingFirstValue(entities) { $0.entityID }
        stateByID = Self.dictionaryKeepingFirstValue(states) { $0.entityID }
        applyStateMetadata(refreshedStates: states)
        rebuildTiles()
    }

    private func startListening(
        context: HankRemoteConnectionContext,
        services: AppServices
    ) {
        stopListening()
        listenTask = Task {
            let stream = services.homeAssistantService.subscribeToStateChanges(
                context: context
            )

            do {
                for try await state in stream {
                    let previousState = stateByID[state.entityID]
                    let isPinned = shortcuts.contains { $0.entityID == state.entityID }
                    stateByID[state.entityID] = state
                    if let entity = entityByID[state.entityID] {
                        entityByID[state.entityID] = entity.merged(with: state)
                        availableEntities = entityByID.values.sorted {
                            $0.suggestedLabel.localizedCaseInsensitiveCompare($1.suggestedLabel) == .orderedAscending
                        }
                    } else if let entity = Self.entitySummary(from: state) {
                        entityByID[state.entityID] = entity
                        availableEntities = entityByID.values.sorted {
                            $0.suggestedLabel.localizedCaseInsensitiveCompare($1.suggestedLabel) == .orderedAscending
                        }
                    }
                    if
                        isPinned,
                        let previousState,
                        previousState.state != state.state,
                        let url = URL(string: "hank://notifications/dashboard/\(state.entityID)")
                    {
                        let title = state.friendlyName ?? entityByID[state.entityID]?.friendlyName ?? state.entityID
                        let value = state.state.replacingOccurrences(of: "_", with: " ").capitalized
                        Task {
                            await services.notificationService.presentLocalNotification(
                                HankLocalNotification(
                                    category: .dashboardEntities,
                                    title: "Dashboard Changed",
                                    body: "\(title) is now \(value).",
                                    url: url,
                                    threadID: "dashboard:\(state.entityID)"
                                )
                            )
                        }
                    }
                    rebuildTiles()
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func rebuildTiles() {
        tiles = sort(shortcuts).compactMap { shortcut in
            guard let entity = entityByID[shortcut.entityID] else {
                return nil
            }

            return DashboardTileModel(
                shortcut: shortcut,
                entity: entity,
                state: stateByID[shortcut.entityID]
            )
        }
    }

    private func applyStateMetadata(refreshedStates: [HAEntityState]) {
        let refreshedStateByID = Self.dictionaryKeepingFirstValue(refreshedStates) { $0.entityID }
        entityByID = entityByID.mapValues { entity in
            entity.merged(with: refreshedStateByID[entity.entityID])
        }
        availableEntities = entityByID.values.sorted {
            $0.suggestedLabel.localizedCaseInsensitiveCompare($1.suggestedLabel) == .orderedAscending
        }
    }

    private static func dictionaryKeepingFirstValue<Value, Key: Hashable>(
        _ values: [Value],
        key: (Value) -> Key
    ) -> [Key: Value] {
        var dictionary: [Key: Value] = [:]
        dictionary.reserveCapacity(values.count)

        for value in values {
            let dictionaryKey = key(value)
            if dictionary[dictionaryKey] == nil {
                dictionary[dictionaryKey] = value
            }
        }

        return dictionary
    }

    private func relocate(shortcut: DashboardShortcut, toRow row: Int, column: Int, modelContext: ModelContext) {
        shortcut.gridRow = max(0, row)
        shortcut.gridColumn = normalizedColumn(for: shortcut.tileSize, proposed: column)

        let displaced = sort(shortcuts.filter { $0.id != shortcut.id && overlaps($0, shortcut) })
        let displacedIDs = Set(displaced.map(\.id))
        var settled = sort(shortcuts.filter { $0.id != shortcut.id && !displacedIDs.contains($0.id) })
        settled.append(shortcut)

        for displacedShortcut in displaced {
            let slot = firstAvailableSlot(for: displacedShortcut.tileSize, among: settled)
            displacedShortcut.gridRow = slot.row
            displacedShortcut.gridColumn = slot.column
            settled.append(displacedShortcut)
        }

        shortcuts = sort(shortcuts)
        normalizeSortOrder()
        save(modelContext)
        rebuildTiles()
    }

    private func overlaps(_ lhs: DashboardShortcut, _ rhs: DashboardShortcut) -> Bool {
        !Set(occupiedCells(for: lhs)).isDisjoint(with: occupiedCells(for: rhs))
    }

    private func occupiedCells(for shortcut: DashboardShortcut) -> [GridKey] {
        if shortcut.tileSize == .expanded {
            return [
                GridKey(row: shortcut.gridRow, column: 0),
                GridKey(row: shortcut.gridRow, column: 1)
            ]
        }

        return [GridKey(row: shortcut.gridRow, column: shortcut.gridColumn)]
    }

    private func firstAvailableSlot(for tileSize: DashboardTileSize, among shortcuts: [DashboardShortcut]) -> GridKey {
        let occupied = Set(shortcuts.flatMap(occupiedCells(for:)))
        let searchLimit = max(shortcuts.map(\.gridRow).max() ?? 0, shortcuts.count + 2) + 4

        for row in 0 ... searchLimit {
            switch tileSize {
            case .expanded:
                let candidateA = GridKey(row: row, column: 0)
                let candidateB = GridKey(row: row, column: 1)
                if !occupied.contains(candidateA), !occupied.contains(candidateB) {
                    return candidateA
                }
            case .compact:
                for column in 0 ... 1 {
                    let candidate = GridKey(row: row, column: column)
                    if !occupied.contains(candidate) {
                        return candidate
                    }
                }
            }
        }

        return GridKey(row: searchLimit + 1, column: 0)
    }

    private func normalizedColumn(for tileSize: DashboardTileSize, proposed column: Int) -> Int {
        switch tileSize {
        case .expanded:
            return 0
        case .compact:
            return max(0, min(1, column))
        }
    }

    private func normalizeSortOrder() {
        shortcuts = sort(shortcuts)
        for (index, shortcut) in shortcuts.enumerated() {
            shortcut.sortOrder = index
        }
    }

    private func sort(_ shortcuts: [DashboardShortcut]) -> [DashboardShortcut] {
        shortcuts.sorted { lhs, rhs in
            if lhs.gridRow != rhs.gridRow {
                return lhs.gridRow < rhs.gridRow
            }
            if lhs.gridColumn != rhs.gridColumn {
                return lhs.gridColumn < rhs.gridColumn
            }
            if lhs.sortOrder != rhs.sortOrder {
                return lhs.sortOrder < rhs.sortOrder
            }
            return lhs.entityID < rhs.entityID
        }
    }

    private func save(_ modelContext: ModelContext) {
        do {
            try modelContext.save()
            if let currentProfileID, let services {
                Task { @MainActor in
                    try? await services.profileSyncCoordinator.pushExplicitProfileSnapshot(
                        profileID: currentProfileID,
                        modelContext: modelContext,
                        services: services
                    )
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private nonisolated static func searchTokens(for value: String) -> [String] {
        value
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private nonisolated static func singularSearchToken(_ token: String) -> String? {
        guard token.count > 3, token.hasSuffix("s") else {
            return nil
        }
        return String(token.dropLast())
    }
}

private struct GridKey: Hashable {
    let row: Int
    let column: Int
}
