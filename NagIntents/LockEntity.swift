import AppIntents
import Foundation
import NagCore

struct LockEntity: AppEntity, Identifiable {
    var id: UUID
    var name: String
    var symbol: String
    var isEngaged: Bool
    var isShielding: Bool

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Lock"
    static let defaultQuery = LockEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: name),
            image: .init(systemName: symbol)
        )
    }

    init(_ profile: LockProfile, now: Date) {
        id = profile.id
        name = profile.name
        symbol = profile.symbol
        isEngaged = profile.isEngaged
        isShielding = profile.isShielding(at: now)
    }
}

struct LockEntityQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [LockEntity] {
        let state = SharedStore.shared.load()
        let ids = Set(identifiers)
        return entities(in: state).filter { ids.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [LockEntity] {
        let state = SharedStore.shared.load()
        return entities(in: state).filter { $0.name.localizedStandardContains(string) }
    }

    func suggestedEntities() async throws -> [LockEntity] {
        let state = SharedStore.shared.load()
        return entities(in: state).sorted {
            if $0.isEngaged != $1.isEngaged { return $0.isEngaged }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func entities(in state: NagState) -> [LockEntity] {
        let now = Date.now
        return state.profiles.map { LockEntity($0, now: now) }
    }
}
