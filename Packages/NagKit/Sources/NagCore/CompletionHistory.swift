import Foundation

/// One finished occurrence of a nag, kept for the weekly review.
public struct CompletionRecord: Codable, Hashable, Sendable {
    public var nagID: UUID
    /// The nag's title when it was done, so the review can still name nags that were deleted since.
    public var title: String
    /// When the occurrence was due.
    public var scheduledAt: Date
    /// When it was marked done.
    public var completedAt: Date
    /// When it was started, if it was started before it was done.
    public var startedAt: Date?
    /// Snoozes used on the occurrence.
    public var snoozes: Int
    /// The nag's key was scanned to prove it.
    public var keyScanned: Bool

    public init(
        nagID: UUID,
        title: String,
        scheduledAt: Date,
        completedAt: Date,
        startedAt: Date? = nil,
        snoozes: Int = 0,
        keyScanned: Bool = false
    ) {
        self.nagID = nagID
        self.title = title
        self.scheduledAt = scheduledAt
        self.completedAt = completedAt
        self.startedAt = startedAt
        self.snoozes = snoozes
        self.keyScanned = keyScanned
    }

    /// How long after it was due the nag was started, or done if it was never started. Getting to it
    /// early counts as on time.
    public var startDelay: TimeInterval {
        max(0, (startedAt ?? completedAt).timeIntervalSince(scheduledAt))
    }
}

/// Completions of one nag in one week, after the individual records were rolled up to save space.
public struct CompletionRollup: Codable, Hashable, Sendable {
    public var nagID: UUID
    public var title: String
    /// Start of the week, in the calendar used when it was rolled up.
    public var weekStart: Date
    public var count: Int
    /// Sum of the records' `startDelay`s.
    public var totalStartDelay: TimeInterval
    public var snoozes: Int
    public var keyScans: Int

    public init(
        nagID: UUID,
        title: String,
        weekStart: Date,
        count: Int = 0,
        totalStartDelay: TimeInterval = 0,
        snoozes: Int = 0,
        keyScans: Int = 0
    ) {
        self.nagID = nagID
        self.title = title
        self.weekStart = weekStart
        self.count = count
        self.totalStartDelay = totalStartDelay
        self.snoozes = snoozes
        self.keyScans = keyScans
    }

    /// A moment safely inside the rolled-up week, even if the time zone has changed since. Use this, not
    /// `weekStart`, to find which week the rollup belongs to.
    public var midweek: Date { weekStart.addingTimeInterval(3.5 * 86_400) }
}

/// A change to the history, found by comparing the nag store before and after a write.
public enum CompletionChange: Hashable, Sendable {
    case completed(CompletionRecord)
    case undone(nagID: UUID, completedAt: Date)
}

/// What got done, kept on this device in its own file so extensions that load the nags don't pay for
/// it. Recent completions are kept individually; older ones are rolled up into weekly totals per nag.
public struct CompletionHistory: Codable, Hashable, Sendable {
    /// Weeks of individual records kept, counting the current week. Older records are rolled up.
    public static let detailWeeks = 10
    /// Most individual records kept, whatever their age. The oldest beyond this are rolled up.
    public static let maxRecords = 1_500
    /// Most weekly rollups kept. The oldest beyond this are dropped.
    public static let maxRollups = 1_000

    /// Oldest first.
    public var records: [CompletionRecord]
    /// Oldest week first.
    public var rollups: [CompletionRollup]

    public init(records: [CompletionRecord] = [], rollups: [CompletionRollup] = []) {
        self.records = records
        self.rollups = rollups
    }

    private enum CodingKeys: String, CodingKey {
        case records, rollups
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        records = try c.decodeIfPresent([CompletionRecord].self, forKey: .records) ?? []
        rollups = try c.decodeIfPresent([CompletionRollup].self, forKey: .rollups) ?? []
    }

    public var isEmpty: Bool { records.isEmpty && rollups.isEmpty }

    /// Adds a completion. The same completion seen twice, say once here and again through iCloud, is
    /// only kept once.
    public mutating func record(_ record: CompletionRecord) {
        guard !records.contains(where: { $0.nagID == record.nagID && $0.completedAt == record.completedAt }) else { return }
        let index = records.lastIndex { $0.completedAt <= record.completedAt }.map { $0 + 1 } ?? 0
        records.insert(record, at: index)
    }

    /// Forgets a completion that was undone.
    public mutating func removeCompletion(nagID: UUID, completedAt: Date) {
        records.removeAll { $0.nagID == nagID && $0.completedAt == completedAt }
    }

    public mutating func apply(_ changes: [CompletionChange]) {
        for change in changes {
            switch change {
            case .completed(let record): self.record(record)
            case .undone(let nagID, let completedAt): removeCompletion(nagID: nagID, completedAt: completedAt)
            }
        }
    }

    /// Rolls up records from before the last `detailWeeks` weeks, and anything past `maxRecords`, into
    /// weekly totals per nag. Then drops the oldest rollups past `maxRollups`.
    public mutating func prune(now: Date, calendar: Calendar) {
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let cutoff = calendar.date(byAdding: .weekOfYear, value: -(Self.detailWeeks - 1), to: thisWeek) ?? thisWeek
        var keep = records.drop { $0.completedAt < cutoff }
        var old = Array(records.prefix(records.count - keep.count))
        if keep.count > Self.maxRecords {
            old += keep.prefix(keep.count - Self.maxRecords)
            keep = keep.suffix(Self.maxRecords)
        }
        guard !old.isEmpty || rollups.count > Self.maxRollups else { return }
        records = Array(keep)

        for record in old {
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: record.completedAt)?.start
                ?? calendar.startOfDay(for: record.completedAt)
            let index: Int
            if let existing = rollups.firstIndex(where: { $0.nagID == record.nagID && $0.weekStart == weekStart }) {
                index = existing
            } else {
                rollups.append(CompletionRollup(nagID: record.nagID, title: record.title, weekStart: weekStart))
                index = rollups.count - 1
            }
            rollups[index].title = record.title
            rollups[index].count += 1
            rollups[index].totalStartDelay += record.startDelay
            rollups[index].snoozes += record.snoozes
            rollups[index].keyScans += record.keyScanned ? 1 : 0
        }
        rollups.sort { ($0.weekStart, $0.nagID.uuidString) < ($1.weekStart, $1.nagID.uuidString) }
        if rollups.count > Self.maxRollups {
            rollups.removeFirst(rollups.count - Self.maxRollups)
        }
    }

    /// The completions made and undone between two versions of the nag store.
    ///
    /// Every way of finishing a nag (the app, the Mac, widgets, Siri, notifications, MCP, and other
    /// devices through iCloud) ends with `NagTask.complete`, which leaves a fresh `completionUndo`
    /// snapshot of the occurrence it finished. That snapshot still has the snoozes and start time from
    /// before completing reset them. Undoing sets `undoneCompletionAt`.
    public static func changes(from before: NagState, to after: NagState) -> [CompletionChange] {
        var previous: [UUID: NagTask] = [:]
        for task in before.tasks where previous[task.id] == nil { previous[task.id] = task }

        var changes: [CompletionChange] = []
        for task in after.tasks {
            let old = previous[task.id]
            if let undone = task.undoneCompletionAt, undone != old?.undoneCompletionAt {
                changes.append(.undone(nagID: task.id, completedAt: undone))
            }
            guard let snapshot = task.completionUndo,
                  snapshot.completedAtMoment != old?.completionUndo?.completedAtMoment,
                  task.lastCompletedAt == snapshot.completedAtMoment,
                  task.undoneCompletionAt != snapshot.completedAtMoment
            else { continue }
            let completedAt = snapshot.completedAtMoment
            // A start from an earlier occurrence, or after the fact, isn't when this one was started.
            let startedAt = snapshot.startedAt.flatMap { $0 >= snapshot.startAt && $0 <= completedAt ? $0 : nil }
            changes.append(.completed(CompletionRecord(
                nagID: task.id,
                title: task.title,
                scheduledAt: snapshot.startAt,
                completedAt: completedAt,
                startedAt: startedAt,
                snoozes: snapshot.snoozeCount,
                keyScanned: snapshot.keyScanned
            )))
        }
        return changes
    }
}
