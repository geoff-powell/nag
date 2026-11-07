import AppIntents
import GeoToolbox
import NagKit

// The entities and enums the Create Reminder schema requires, for `CreateNagReminderIntent`. They're
// assistant-only: Shortcuts works with `NagEntity` (iPhone) and the Create Nag action instead.

/// A nag, as the reminder Apple Intelligence asked for.
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .reminders.reminder)
struct NagReminderEntity {
    static let isAssistantOnly = true
    static let defaultQuery = NagReminderQuery()

    let id: UUID
    var title: String
    var note: AttributedString?
    var tags: Set<String>
    var urls: [URL]
    var dueDate: DateComponents?
    var recurrence: Calendar.RecurrenceRule?
    var isCompleted: Bool
    var isFlagged: Bool?
    var creationDate: Date?
    var completionDate: Date?
    var list: NagListEntity
    var locationTrigger: NagPlaceTriggerEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    init(_ task: NagTask, calendar: Calendar) {
        id = task.id
        title = task.title
        note = task.notes.isEmpty ? nil : AttributedString(task.notes)
        tags = []
        urls = task.link.map { [$0] } ?? []
        dueDate = calendar.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute],
            from: task.nagStart ?? task.startAt
        )
        recurrence = task.recurrenceRule(calendar: calendar)
        isCompleted = task.isFinished
        isFlagged = nil
        creationDate = task.createdAt
        completionDate = task.completedAt
        list = NagListEntity()
        locationTrigger = nil
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct NagReminderQuery: EntityQuery {
    @Dependency private var model: CreateNagModel

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [NagReminderEntity] {
        let ids = Set(identifiers)
        return model.store.load().tasks
            .filter { ids.contains($0.id) }
            .map { NagReminderEntity($0, calendar: model.calendar) }
    }
}

/// Nag keeps every nag in one list.
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .reminders.list)
struct NagListEntity: UniqueAppEntity {
    static let isAssistantOnly = true
    static let defaultQuery = NagListQuery()

    let id: String
    var name: String
    var type: NagListType

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init() {
        id = "nags"
        name = "Nags"
        type = .standard
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct NagListQuery: UniqueAppEntityQuery {
    func uniqueEntity() async throws -> NagListEntity {
        NagListEntity()
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .reminders.listType)
enum NagListType: String {
    case standard

    static let isAssistantOnly = true
    static let caseDisplayRepresentations: [NagListType: DisplayRepresentation] = [.standard: "List"]
}

/// Nag lists have no sections, so there's never one to find.
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .reminders.section)
struct NagSectionEntity {
    static let isAssistantOnly = true
    static let defaultQuery = NagSectionQuery()

    let id: String
    var name: String
    var list: NagListEntity

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct NagSectionQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [NagSectionEntity] { [] }
    func entities(matching string: String) async throws -> [NagSectionEntity] { [] }
}

/// A place Siri heard, as in "when I get home". `CreateNagReminderIntent` refuses it: Nag can't start a
/// nag at a place yet.
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .reminders.locationTrigger)
struct NagPlaceTriggerEntity: TransientAppEntity {
    static let isAssistantOnly = true

    var place: PlaceDescriptor
    var event: NagPlaceTriggerEvent

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(place.commonName ?? "A place")")
    }

    init() {
        place = PlaceDescriptor(representations: [], commonName: nil)
        event = .arrive
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .reminders.locationTriggerEvent)
enum NagPlaceTriggerEvent: String {
    case arrive
    case depart

    static let isAssistantOnly = true
    static let caseDisplayRepresentations: [NagPlaceTriggerEvent: DisplayRepresentation] = [
        .arrive: "Arrive",
        .depart: "Leave",
    ]
}
