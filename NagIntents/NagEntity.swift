import AppIntents
import Foundation
import NagCore

struct NagEntity: AppEntity, Identifiable {
    var id: UUID
    var title: String
    var dueAt: Date
    var isOverdue: Bool
    var isSnoozed: Bool
    var needsKeyScan: Bool

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Nag"
    static let defaultQuery = NagEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: title),
            subtitle: "Due \(dueAt.formatted(date: .abbreviated, time: .shortened))"
        )
    }

    init(_ task: NagTask, state: NagState, now: Date, calendar: Calendar) {
        id = task.id
        title = task.title
        dueAt = task.nagStart ?? task.startAt
        isOverdue = task.isNagging(at: now)
        isSnoozed = task.isSnoozed(at: now)
        needsKeyScan = WidgetSnapshot.needsKeyScan(task, in: state)
    }

    init(summary: NagSummary) {
        id = summary.id
        title = summary.title
        dueAt = summary.dueAt
        isOverdue = summary.isOverdue
        isSnoozed = summary.isSnoozed
        needsKeyScan = summary.needsKeyScan
    }
}

struct NagEntityQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [NagEntity] {
        let state = SharedStore.shared.load()
        let ids = Set(identifiers)
        let now = Date.now
        return state.tasks
            .filter { ids.contains($0.id) }
            .map { NagEntity($0, state: state, now: now, calendar: .current) }
    }

    func entities(matching string: String) async throws -> [NagEntity] {
        let state = SharedStore.shared.load()
        return entities(in: state).filter { $0.title.localizedStandardContains(string) }
    }

    func suggestedEntities() async throws -> [NagEntity] {
        let state = SharedStore.shared.load()
        let now = Date.now
        return WidgetSnapshot.make(from: state, now: now, calendar: .current, limit: 10)
            .due.map(NagEntity.init(summary:))
    }

    private func entities(in state: NagState) -> [NagEntity] {
        let now = Date.now
        return state.tasks
            .filter { !$0.isFinished }
            .map { NagEntity($0, state: state, now: now, calendar: .current) }
    }
}
