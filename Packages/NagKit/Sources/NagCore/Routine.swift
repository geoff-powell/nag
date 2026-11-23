import Foundation

// MARK: - Model

/// One small step of a routine, such as "Shoes on" on the way out the door.
public struct RoutineStep: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    /// Roughly how long the step takes. `nil` when the user didn't say.
    public var estimateMinutes: Int?

    public init(id: UUID = UUID(), title: String, estimateMinutes: Int? = nil) {
        self.id = id
        self.title = title
        self.estimateMinutes = estimateMinutes.map { min(max($0, 1), 1440) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, estimateMinutes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        estimateMinutes = try c.decodeIfPresent(Int.self, forKey: .estimateMinutes).map { min(max($0, 1), 1440) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(estimateMinutes, forKey: .estimateMinutes)
    }
}

/// The steps done so far in one occurrence of a nag.
///
/// Progress is never cleared explicitly. It belongs to the occurrence identified by `occurrence` (the
/// nag's `startAt`) and `after` (its `lastCompletedAt`), so it stops applying the moment the nag is
/// completed, rolls over or is reopened, even when an older build did that, and applies again if the
/// completion is undone.
public struct StepProgress: Codable, Hashable, Sendable {
    /// `startAt` of the occurrence these steps were done in.
    public var occurrence: Date
    /// `lastCompletedAt` when these steps were done.
    public var after: Date?
    public var done: Set<UUID>
    public var updatedAt: Date

    public init(occurrence: Date, after: Date?, done: Set<UUID> = [], updatedAt: Date) {
        self.occurrence = occurrence
        self.after = after
        self.done = done
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case occurrence, after, done, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        occurrence = try c.decode(Date.self, forKey: .occurrence)
        after = try c.decodeIfPresent(Date.self, forKey: .after)
        done = Set(try c.decodeIfPresent([UUID].self, forKey: .done) ?? [])
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? occurrence
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(occurrence, forKey: .occurrence)
        try c.encodeIfPresent(after, forKey: .after)
        // Sorted, so the same progress always encodes to the same bytes.
        try c.encode(done.sorted { $0.uuidString < $1.uuidString }, forKey: .done)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    func applies(to task: NagTask) -> Bool {
        occurrence == task.startAt && after == task.lastCompletedAt
    }

    /// Same occurrence: every step done on either device stays done. Different occurrences: the later
    /// one wins. Order independent, like `TaskMerge`.
    public static func merge(_ a: StepProgress?, _ b: StepProgress?) -> StepProgress? {
        guard let a else { return b }
        guard let b else { return a }
        if a.occurrence == b.occurrence, a.after == b.after {
            return StepProgress(
                occurrence: a.occurrence,
                after: a.after,
                done: a.done.union(b.done),
                updatedAt: max(a.updatedAt, b.updatedAt)
            )
        }
        let keyA = (a.occurrence, a.after ?? .distantPast, a.updatedAt)
        let keyB = (b.occurrence, b.after ?? .distantPast, b.updatedAt)
        return keyA >= keyB ? a : b
    }
}

/// A nag's ordered steps and how far through them the current occurrence is.
///
/// Synced under its own iCloud key (see `RoutineSidecar`) rather than inside the nag, so older builds,
/// which drop fields they don't know when they rewrite a nag, can't lose it.
public struct NagRoutine: Codable, Hashable, Sendable {
    public var steps: [RoutineStep]
    /// When the steps were last edited. Steps merge on this, separately from the nag's `updatedAt`, so an
    /// older build touching the nag doesn't make its step-less copy win.
    public var updatedAt: Date
    public var progress: StepProgress?

    public init(steps: [RoutineStep] = [], updatedAt: Date, progress: StepProgress? = nil) {
        self.steps = steps
        self.updatedAt = updatedAt
        self.progress = progress
    }

    private enum CodingKeys: String, CodingKey {
        case steps, updatedAt, progress
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        steps = try c.decodeIfPresent([RoutineStep].self, forKey: .steps) ?? []
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        progress = try? c.decodeIfPresent(StepProgress.self, forKey: .progress)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(steps, forKey: .steps)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(progress, forKey: .progress)
    }

    /// The most recent step edit wins; progress merges on its own. `nil` means "unknown", such as a copy
    /// from an older build, and never wins over real steps.
    public static func merge(_ a: NagRoutine?, _ b: NagRoutine?) -> NagRoutine? {
        guard let a else { return b }
        guard let b else { return a }
        var winner: NagRoutine
        if a.updatedAt != b.updatedAt {
            winner = a.updatedAt > b.updatedAt ? a : b
        } else {
            winner = signature(a) >= signature(b) ? a : b
        }
        winner.progress = StepProgress.merge(a.progress, b.progress)
        return winner
    }

    private static func signature(_ routine: NagRoutine) -> String {
        routine.steps.map { "\($0.id.uuidString)|\($0.title)|\($0.estimateMinutes ?? 0)" }.joined(separator: ",")
    }

    /// When the steps left would be done if started now. `nil` when none of them has an estimate.
    public static func estimatedFinish(remaining: [RoutineStep], now: Date) -> Date? {
        let estimates = remaining.compactMap(\.estimateMinutes)
        guard !estimates.isEmpty else { return nil }
        return now.addingTimeInterval(TimeInterval(estimates.reduce(0, +) * 60))
    }
}

// MARK: - Rules

extension NagTask {
    /// The nag's steps, in order. Empty for a plain nag.
    public var steps: [RoutineStep] {
        get { routine?.steps ?? [] }
        set {
            guard newValue != steps else { return }
            // `NagState.save` stamps the real edit time.
            if routine == nil {
                routine = NagRoutine(steps: newValue, updatedAt: .distantPast)
            } else {
                routine?.steps = newValue
            }
        }
    }

    public var hasSteps: Bool { !steps.isEmpty }

    /// Steps done in the current occurrence. Empty once the nag is completed, rolls over or is reopened.
    public var completedStepIDs: Set<UUID> {
        guard !isFinished, let progress = routine?.progress, progress.applies(to: self) else { return [] }
        return progress.done.intersection(steps.map(\.id))
    }

    /// The steps not yet done in the current occurrence, in order.
    public var remainingSteps: [RoutineStep] {
        let done = completedStepIDs
        return steps.filter { !done.contains($0.id) }
    }

    /// The step to do next. `nil` for a plain nag, or once every step is done.
    public var currentStep: RoutineStep? { remainingSteps.first }

    /// 1-based position of the current step, for "Step 2 of 5".
    public var currentStepNumber: Int? {
        guard let current = currentStep else { return nil }
        return steps.firstIndex { $0.id == current.id }.map { $0 + 1 }
    }

    /// Every step is done, but the nag itself isn't yet (it's waiting for a key scan, say, or a
    /// completion was undone).
    public var allStepsDone: Bool { hasSteps && !isFinished && remainingSteps.isEmpty }

    /// "Step 2 of 5", or `nil` for a plain nag.
    public var stepLabel: String? {
        guard hasSteps, !isFinished else { return nil }
        guard let number = currentStepNumber else { return "All \(steps.count) steps done" }
        return "Step \(number) of \(steps.count)"
    }

    /// When the routine would be done if the remaining steps run to their estimates from `now`.
    public func estimatedFinish(at now: Date) -> Date? {
        NagRoutine.estimatedFinish(remaining: remainingSteps, now: now)
    }

    /// Marks the current step done. Counts as starting the nag: escalation pauses for the next step's
    /// estimate, or the nag's working time if it has none. Returns true when that was the last step, so
    /// the caller can complete the nag through its normal path (which may still need a key scan).
    @discardableResult
    public mutating func completeCurrentStep(at now: Date, calendar: Calendar) -> Bool {
        guard canComplete(at: now, calendar: calendar), let step = currentStep else { return allStepsDone }
        var progress = routine?.progress.flatMap { $0.applies(to: self) ? $0 : nil }
            ?? StepProgress(occurrence: startAt, after: lastCompletedAt, updatedAt: now)
        progress.done.insert(step.id)
        progress.updatedAt = now
        routine?.progress = progress
        if isOutstanding(at: now) { startedAt = now }
        updatedAt = now
        return remainingSteps.isEmpty
    }

    /// How long a started nag stays quiet. A routine pauses for the current step's estimate, so a
    /// two-minute step doesn't buy half an hour of silence.
    var workSeconds: TimeInterval {
        TimeInterval((currentStep?.estimateMinutes ?? style.workMinutes) * 60)
    }

    /// Drops blank steps and tidies titles.
    mutating func tidySteps() {
        guard routine != nil else { return }
        let tidied = steps
            .map { RoutineStep(id: $0.id, title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines), estimateMinutes: $0.estimateMinutes) }
            .filter { !$0.title.isEmpty }
        if tidied != steps { routine?.steps = tidied }
    }
}

// MARK: - Sync

/// Splits routines out of the synced nags so they can live under their own iCloud key.
///
/// Builds from before routines decode nags from `CloudTaskSync.storageKey` and write them back with only
/// the fields they know, so steps stored inside a nag would be dropped the first time an older build
/// touched it. Old builds never read or write `CloudTaskSync.routinesKey`, so steps kept there survive.
public enum RoutineSidecar {
    /// Nags without their routines, for the nags key, and the routines by nag ID, for the sidecar key.
    public static func split(_ synced: SyncedTasks) -> (tasks: SyncedTasks, routines: [String: NagRoutine]) {
        var routines: [String: NagRoutine] = [:]
        var tasks = synced.tasks
        for index in tasks.indices {
            if let routine = tasks[index].routine { routines[tasks[index].id.uuidString] = routine }
            tasks[index].routine = nil
        }
        return (SyncedTasks(tasks: tasks, deleted: synced.deleted), routines)
    }

    /// Attaches routines to the nags they belong to, merging with any routine a nag already carries.
    public static func join(_ synced: SyncedTasks, routines: [String: NagRoutine]) -> SyncedTasks {
        var joined = synced
        for index in joined.tasks.indices {
            let id = joined.tasks[index].id.uuidString
            joined.tasks[index].routine = NagRoutine.merge(joined.tasks[index].routine, routines[id])
        }
        return joined
    }

    /// The sidecar to write after a merge: the merged nags' routines, plus routines from `remote` whose
    /// nag hasn't arrived yet (the two keys can sync separately) and hasn't been deleted.
    public static func routines(for merged: SyncedTasks, keeping remote: [String: NagRoutine]) -> [String: NagRoutine] {
        var result = split(merged).routines
        let known = Set(merged.tasks.map(\.id.uuidString))
        for (id, routine) in remote where !known.contains(id) && merged.deleted[id] == nil {
            result[id] = routine
        }
        return result
    }
}
