import Foundation

/// The part of the state that syncs between devices. Locks and keys stay on the device they were made
/// on, because blocked apps and NFC tags are device specific.
public struct SyncedTasks: Codable, Hashable, Sendable {
    public var tasks: [NagTask]
    /// Deleted nag IDs and when they were deleted.
    public var deleted: [String: Date]

    public init(tasks: [NagTask] = [], deleted: [String: Date] = [:]) {
        self.tasks = tasks
        self.deleted = deleted
    }
}

public enum TaskMerge {
    /// How long deletions are remembered. A device offline for longer could bring a deleted nag back.
    public static let tombstoneLifetime: TimeInterval = 30 * 86_400

    /// Merges two copies of the synced nags. Deterministic and order independent, so every device
    /// converges on the same result.
    public static func merge(_ local: SyncedTasks, _ remote: SyncedTasks, now: Date) -> SyncedTasks {
        let deleted = local.deleted
            .merging(remote.deleted) { max($0, $1) }
            .filter { now.timeIntervalSince($0.value) < tombstoneLifetime }

        var byID: [UUID: NagTask] = [:]
        for task in local.tasks + remote.tasks {
            byID[task.id] = byID[task.id].map { merge($0, task) } ?? task
        }

        let tasks = byID.values
            .filter { task in
                guard let deletedAt = deleted[task.id.uuidString] else { return true }
                return task.updatedAt > deletedAt
            }
            .sorted(by: canonicalOrder)
        return SyncedTasks(tasks: tasks, deleted: deleted)
    }

    /// The most recent edit wins, except that a completion is never lost: if the older copy recorded a
    /// later completion (say, done on the phone while the Mac snoozed a stale copy), keep it.
    public static func merge(_ a: NagTask, _ b: NagTask) -> NagTask {
        guard a != b else { return a }
        var (newer, older) = a.updatedAt != b.updatedAt
            ? (a.updatedAt > b.updatedAt ? (a, b) : (b, a))
            : (a.id.uuidString >= b.id.uuidString && a.title >= b.title ? (a, b) : (b, a))
        let undone = max(a.undoneCompletionAt ?? .distantPast, b.undoneCompletionAt ?? .distantPast)
        let undoneCopy = newer.undoneCompletionAt == undone && newer.lastCompletedAt != undone
            ? newer
            : older
        newer.undoneCompletionAt = undone == .distantPast ? nil : undone

        if undone != .distantPast,
           let newerDone = newer.lastCompletedAt,
           newerDone <= undone {
            newer.startAt = undoneCopy.startAt
            newer.lastCompletedAt = undoneCopy.lastCompletedAt
            newer.completedAt = undoneCopy.completedAt
            newer.snoozedUntil = undoneCopy.snoozedUntil
            newer.snoozeCount = undoneCopy.snoozeCount
            newer.completionUndo = undoneCopy.completionUndo
        } else if let olderDone = older.lastCompletedAt,
           olderDone > (newer.lastCompletedAt ?? .distantPast),
           olderDone > undone {
            newer.lastCompletedAt = olderDone
            newer.completedAt = older.completedAt ?? newer.completedAt
            if newer.isRepeating { newer.startAt = max(newer.startAt, older.startAt) }
            newer.snoozedUntil = older.snoozedUntil
            newer.snoozeCount = older.snoozeCount
            newer.completionUndo = older.completionUndo
        }
        return newer
    }

    public static func canonicalOrder(_ a: NagTask, _ b: NagTask) -> Bool {
        (a.createdAt, a.id.uuidString) < (b.createdAt, b.id.uuidString)
    }
}

extension NagState {
    public var syncedTasks: SyncedTasks {
        SyncedTasks(tasks: tasks.sorted(by: TaskMerge.canonicalOrder), deleted: deletedTasks)
    }

    public mutating func apply(_ synced: SyncedTasks) {
        tasks = synced.tasks
        deletedTasks = synced.deleted
    }

    public mutating func deleteTask(_ id: UUID, at now: Date) {
        tasks.removeAll { $0.id == id }
        deletedTasks[id.uuidString] = now
    }
}
