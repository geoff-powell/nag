import Foundation

/// Process-agnostic actions for intents and extensions. Deliberately exposes no way to unlock,
/// relock or emergency-unlock a profile: only the UI may move a lock toward being less engaged.
public enum NagActions {
    public enum Failure: Error, Hashable, Sendable {
        case noSuchNag
        case noSuchLock
        /// The nag can only be completed by scanning its key. Carries enough to build a scan deep link.
        case needsKeyScan(taskID: UUID, keyName: String)
        case cannotComplete
        case cannotSnooze
        case cannotStart
    }

    @discardableResult
    public static func complete(
        taskID: UUID,
        store: SharedStore = .shared,
        now: Date = .now,
        calendar: Calendar = .current
    ) throws(Failure) -> NagTask {
        let result: Result<NagTask, Failure> = store.update { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == taskID }) else { return .failure(.noSuchNag) }
            let task = state.tasks[index]
            if let keyID = task.proof.keyID, let key = state.key(keyID) {
                return .failure(.needsKeyScan(taskID: taskID, keyName: key.name))
            }
            guard task.canComplete(at: now, calendar: calendar) else { return .failure(.cannotComplete) }
            state.tasks[index].complete(at: now, calendar: calendar)
            return .success(state.tasks[index])
        }
        return try result.get()
    }

    /// What finishing a routine step led to.
    public enum StepOutcome: Hashable, Sendable {
        /// More steps to go.
        case nextStep
        /// That was the last step, and the nag is done.
        case completed
        /// That was the last step, but the nag still needs its key scanned.
        case needsKeyScan(keyName: String)
    }

    /// Marks a routine's current step done. Finishing the last step completes the nag the same way
    /// `complete` does, so a nag that needs a key scan still needs it.
    @discardableResult
    public static func completeStep(
        taskID: UUID,
        store: SharedStore = .shared,
        now: Date = .now,
        calendar: Calendar = .current
    ) throws(Failure) -> StepOutcome {
        let result: Result<StepOutcome, Failure> = store.update { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == taskID }) else { return .failure(.noSuchNag) }
            guard state.tasks[index].hasSteps, state.tasks[index].canComplete(at: now, calendar: calendar) else {
                return .failure(.cannotComplete)
            }
            guard state.tasks[index].completeCurrentStep(at: now, calendar: calendar) else { return .success(.nextStep) }
            if let keyID = state.tasks[index].proof.keyID, let key = state.key(keyID) {
                return .success(.needsKeyScan(keyName: key.name))
            }
            state.tasks[index].complete(at: now, calendar: calendar)
            return .success(.completed)
        }
        return try result.get()
    }

    @discardableResult
    public static func snooze(
        taskID: UUID,
        minutes: Int? = nil,
        store: SharedStore = .shared,
        now: Date = .now,
        calendar: Calendar = .current
    ) throws(Failure) -> NagTask {
        let result: Result<NagTask, Failure> = store.update { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == taskID }) else { return .failure(.noSuchNag) }
            let task = state.tasks[index]
            guard task.canSnooze(at: now) else { return .failure(.cannotSnooze) }
            state.tasks[index].snooze(at: now, minutes: minutes ?? task.style.snoozeMinutes)
            return .success(state.tasks[index])
        }
        return try result.get()
    }

    @discardableResult
    public static func start(
        taskID: UUID,
        store: SharedStore = .shared,
        now: Date = .now,
        calendar: Calendar = .current
    ) throws(Failure) -> NagTask {
        let result: Result<NagTask, Failure> = store.update { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == taskID }) else { return .failure(.noSuchNag) }
            guard state.tasks[index].isOutstanding(at: now), state.tasks[index].startedAt == nil else {
                return .failure(.cannotStart)
            }
            state.tasks[index].start(at: now)
            return .success(state.tasks[index])
        }
        return try result.get()
    }

    @discardableResult
    public static func lockNow(
        profileID: UUID,
        store: SharedStore = .shared,
        now: Date = .now,
        calendar: Calendar = .current
    ) throws(Failure) -> LockProfile {
        let result: Result<LockProfile, Failure> = store.update { state in
            guard let index = state.profiles.firstIndex(where: { $0.id == profileID }) else { return .failure(.noSuchLock) }
            state.profiles[index].lock(at: now)
            return .success(state.profiles[index])
        }
        return try result.get()
    }

    public static func unlockSteps(
        profileID: UUID,
        steps: Int? = nil,
        store: SharedStore = .shared,
        now: Date = .now,
        calendar: Calendar = .current
    ) throws(Failure) -> [RequirementStatus] {
        let state = store.load()
        guard let profile = state.profile(profileID) else { throw .noSuchLock }
        return UnlockEvaluator.evaluate(profile, state: state, steps: steps, now: now, calendar: calendar)
    }
}

extension NagActions.Failure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noSuchNag: "That nag no longer exists."
        case .noSuchLock: "That lock no longer exists."
        case .needsKeyScan(_, let keyName): "Scan “\(keyName)” to complete this nag."
        case .cannotComplete: "This nag can't be completed right now."
        case .cannotSnooze: "This nag can't be snoozed right now."
        case .cannotStart: "This nag can't be started right now."
        }
    }
}
