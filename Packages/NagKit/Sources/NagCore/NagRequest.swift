import Foundation

/// How many snoozes a nag allows per occurrence.
public enum SnoozeLimit: Hashable, Sendable {
    case unlimited
    case limited(Int)
}

/// A nag described from outside Nag: Shortcuts, Siri, or a `nag://add` link from Notes, Calendar,
/// Muse or an AI assistant.
///
/// Only `title` is required. A `nil` field gets Nag's default on a new nag, and leaves the current value
/// alone when the request updates a nag made earlier from the same source item.
public struct NagRequest: Hashable, Sendable {
    public var title: String
    public var notes: String?
    /// When nagging starts. A new nag starts now when this is `nil`. Custom schedules ignore it and start
    /// at their next time.
    public var startAt: Date?
    /// Defaults to `.custom` when `times` are given, otherwise to `.never` for a new nag.
    public var repeatRule: RepeatRule?
    public var times: [NagTime]?
    public var intervalMinutes: Int?
    public var escalation: Escalation?
    public var snoozeMinutes: Int?
    public var snoozeLimit: SnoozeLimit?
    public var breakThroughFocus: Bool?
    /// Who sent this, such as "Calendar" or "Claude". Shown on the nag.
    public var source: String?
    /// The source's ID for the item. Sending the same source and ID again updates the nag.
    public var externalID: String?
    /// Opens the item the nag came from.
    public var link: URL?

    public init(
        title: String,
        notes: String? = nil,
        startAt: Date? = nil,
        repeatRule: RepeatRule? = nil,
        times: [NagTime]? = nil,
        intervalMinutes: Int? = nil,
        escalation: Escalation? = nil,
        snoozeMinutes: Int? = nil,
        snoozeLimit: SnoozeLimit? = nil,
        breakThroughFocus: Bool? = nil,
        source: String? = nil,
        externalID: String? = nil,
        link: URL? = nil
    ) {
        self.title = title
        self.notes = notes
        self.startAt = startAt
        self.repeatRule = repeatRule
        self.times = times
        self.intervalMinutes = intervalMinutes
        self.escalation = escalation
        self.snoozeMinutes = snoozeMinutes
        self.snoozeLimit = snoozeLimit
        self.breakThroughFocus = breakThroughFocus
        self.source = source
        self.externalID = externalID
        self.link = link
    }
}

public enum NagRequestError: Error, Hashable, Sendable {
    case missingTitle
    /// A custom schedule needs at least one time, and every time needs at least one day.
    case invalidSchedule
    case invalidValue(parameter: String, value: String)
    case unsupportedURL
}

extension NagRequestError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingTitle: "A nag needs a title."
        case .invalidSchedule: "Custom times need at least one time, and at least one day for each."
        case .invalidValue(let parameter, let value): "“\(value)” isn't a valid \(parameter)."
        case .unsupportedURL: "Nag doesn't recognize this link."
        }
    }
}

/// The nag a request would save.
public struct NagDraft: Hashable, Sendable {
    public var task: NagTask
    /// The nag before the request changed it. `nil` when the request adds a new nag.
    public var original: NagTask?

    public var isNew: Bool { original == nil }
}

extension NagState {
    /// The nag made earlier from the same source item.
    public func task(source: String?, externalID: String) -> NagTask? {
        tasks.first { $0.externalID == externalID && $0.source == source }
    }

    /// What `request` would save, without changing anything: a new nag, or the nag from the same source
    /// item with the request's changes.
    public func draft(for request: NagRequest, now: Date, calendar: Calendar) throws(NagRequestError) -> NagDraft {
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw .missingTitle }
        try request.validateRanges()

        let source = request.source.nonBlank
        let externalID = request.externalID.nonBlank
        let original = externalID.flatMap { self.task(source: source, externalID: $0) }
        var task = original ?? NagTask(
            title: title,
            startAt: request.startAt ?? now,
            source: source,
            externalID: externalID,
            now: now
        )

        task.title = title
        if let notes = request.notes { task.notes = notes }
        if let startAt = request.startAt { task.startAt = startAt }
        if let times = request.times { task.times = times }
        if let rule = request.repeatRule ?? (request.times == nil ? nil : .custom) { task.repeatRule = rule }
        if let minutes = request.intervalMinutes { task.style.intervalMinutes = minutes }
        if let escalation = request.escalation { task.style.escalation = escalation }
        if let minutes = request.snoozeMinutes { task.style.snoozeMinutes = minutes }
        switch request.snoozeLimit {
        case .unlimited: task.style.maxSnoozes = nil
        case .limited(let count): task.style.maxSnoozes = count
        case nil: break
        }
        if let breakThrough = request.breakThroughFocus { task.style.breakThroughFocus = breakThrough }
        if let link = request.link { task.link = link }

        guard task.hasValidSchedule else { throw .invalidSchedule }
        task.alignStartToSchedule(previous: original, now: now, calendar: calendar)
        // A finished one-off that's been moved, say a rescheduled event, should nag again.
        if let original, original.completedAt != nil, task.startAt != original.startAt {
            task.completedAt = nil
        }
        return NagDraft(task: task, original: original)
    }

    /// Adds the nag `request` describes, or updates the one made earlier from the same source item.
    /// Sending an unchanged item again changes nothing.
    @discardableResult
    public mutating func apply(_ request: NagRequest, now: Date, calendar: Calendar) throws(NagRequestError) -> NagDraft {
        let draft = try self.draft(for: request, now: now, calendar: calendar)
        if let original = draft.original, draft.task == original { return draft }
        return NagDraft(task: save(draft.task, now: now), original: draft.original)
    }

    /// Adds or replaces a nag. Tidies the title, stamps the change for sync, and resets snoozes when the
    /// start moved.
    @discardableResult
    public mutating func save(_ task: NagTask, now: Date) -> NagTask {
        var task = task
        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        task.updatedAt = now
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            if tasks[index].startAt != task.startAt {
                task.snoozedUntil = nil
                task.snoozeCount = 0
                task.startedAt = nil
            }
            tasks[index] = task
        } else {
            tasks.append(task)
        }
        return task
    }
}

extension NagRequest {
    func validateRanges() throws(NagRequestError) {
        if let minutes = intervalMinutes, !(1...1440).contains(minutes) {
            throw .invalidValue(parameter: "nag interval", value: "\(minutes)")
        }
        if let minutes = snoozeMinutes, !(1...1440).contains(minutes) {
            throw .invalidValue(parameter: "snooze length", value: "\(minutes)")
        }
        if case .limited(let count) = snoozeLimit, count < 0 {
            throw .invalidValue(parameter: "snooze limit", value: "\(count)")
        }
    }
}

extension Optional<String> {
    /// Trimmed, or `nil` when empty.
    var nonBlank: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
