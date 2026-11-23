import AppIntents
import Foundation
import NagKit

/// A Focus filter for Nag, set up in Settings > Focus > (a Focus) > Add Filter. While the Focus is on it
/// can turn on chosen locks, quiet nags below a chosen urgency, and switch quiet hours on.
///
/// The system runs `perform()` when the Focus starts and again, with every parameter at its default, when
/// it ends. Defaults mean "no changes", so ending the Focus releases only the locks Focus turned on.
/// Built into the iPhone and Mac apps only: the widget extension can't apply Screen Time shields.
struct NagFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Set Nag Filter"
    static let description = IntentDescription(
        "Turns on locks and quiets less urgent nags while this Focus is on. Locks it turns on switch off again when the Focus ends."
    )

    @Parameter(title: "Turn On Locks", default: [])
    var locks: [FocusLockEntity]

    @Parameter(title: "Nags", default: .all)
    var urgency: FocusUrgencyOption

    @Parameter(title: "Quiet Hours", description: "Pause every nag while this Focus is on.", default: false)
    var quietHours: Bool

    #if os(iOS)
    @Dependency private var model: AppModel
    #else
    @Dependency private var model: MacModel
    #endif

    var displayRepresentation: DisplayRepresentation {
        let summary = FocusFilterSummary.make(
            lockNames: locks.map(\.name),
            minimumUrgency: urgency.urgency,
            quietHours: quietHours
        )
        return DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: summary.title),
            subtitle: LocalizedStringResource(stringLiteral: summary.subtitle)
        )
    }

    /// Hides nags below the chosen urgency from Notification Center too, not just from future delivery.
    var appContext: FocusFilterAppContext {
        FocusFilterAppContext(notificationFilterPredicate: filter.notificationFilterPredicate)
    }

    private var filter: FocusFilter {
        FocusFilter(
            lockStarts: Dictionary(uniqueKeysWithValues: locks.map { ($0.id, Date.distantPast) }),
            minimumUrgency: urgency.urgency,
            quietHours: quietHours
        )
    }

    static func suggestedFocusFilters(for context: FocusFilterSuggestionContext) async -> [NagFocusFilter] {
        var urgentOnly = NagFocusFilter()
        urgentOnly.urgency = .relentless
        var quiet = NagFocusFilter()
        quiet.quietHours = true
        return [urgentOnly, quiet]
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await model.applyFocusFilter(
            lockIDs: Set(locks.map(\.id)),
            minimumUrgency: urgency.urgency,
            quietHours: quietHours
        )
        return .result()
    }
}

enum FocusUrgencyOption: String, AppEnum {
    case all
    case gentle
    case relentless

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Nags"
    static let caseDisplayRepresentations: [FocusUrgencyOption: DisplayRepresentation] = [
        .all: DisplayRepresentation(title: "All nags", subtitle: "Deliver every nag as usual"),
        .gentle: DisplayRepresentation(title: "Gentle and relentless", subtitle: "Quiet steady nags, like Someday"),
        .relentless: DisplayRepresentation(title: "Relentless only", subtitle: "Only urgent nags, like Medication"),
    ]

    var urgency: FocusUrgency {
        switch self {
        case .all: .all
        case .gentle: .gentle
        case .relentless: .relentless
        }
    }
}

/// A lock a Focus filter can turn on. Separate from the iPhone's `LockEntity` so the Mac can use it too.
struct FocusLockEntity: AppEntity, Identifiable {
    var id: UUID
    var name: String
    var symbol: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Lock"
    static let defaultQuery = FocusLockQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name), image: .init(systemName: symbol))
    }

    init(_ profile: LockProfile) {
        id = profile.id
        name = profile.name
        symbol = profile.symbol
    }
}

struct FocusLockQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [FocusLockEntity] {
        let ids = Set(identifiers)
        return all().filter { ids.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [FocusLockEntity] {
        all().filter { $0.name.localizedStandardContains(string) }
    }

    func suggestedEntities() async throws -> [FocusLockEntity] {
        all()
    }

    private func all() -> [FocusLockEntity] {
        SharedStore.shared.load().profiles
            .map(FocusLockEntity.init)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
