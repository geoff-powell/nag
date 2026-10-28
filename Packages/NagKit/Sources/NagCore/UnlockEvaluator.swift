import Foundation

/// Progress on one unlock requirement, ready to display.
public struct RequirementStatus: Identifiable, Hashable, Sendable {
    public var requirement: UnlockRequirement
    public var isMet: Bool
    public var title: String
    public var detail: String
    /// 0...1 where progress is meaningful.
    public var progress: Double?

    public var id: UUID { requirement.id }
}

public enum UnlockEvaluator {
    /// - Parameter steps: Steps walked since the lock started, or `nil` where step counting isn't available.
    public static func evaluate(
        _ profile: LockProfile,
        state: NagState,
        steps: Int?,
        now: Date,
        calendar: Calendar
    ) -> [RequirementStatus] {
        let session = profile.session ?? LockSession(startedAt: now)
        return profile.requirements.map {
            status(of: $0, session: session, state: state, steps: steps, now: now, calendar: calendar)
        }
    }

    public static func allMet(
        _ profile: LockProfile,
        state: NagState,
        steps: Int?,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        evaluate(profile, state: state, steps: steps, now: now, calendar: calendar).allSatisfy(\.isMet)
    }

    /// Requirements met without anyone in the app (nags done, timer run out, proofs already given).
    public static func isAutoUnlockReady(_ profile: LockProfile, state: NagState, now: Date, calendar: Calendar) -> Bool {
        guard profile.autoUnlock, profile.isLocked, !profile.requirements.isEmpty else { return false }
        return allMet(profile, state: state, steps: nil, now: now, calendar: calendar)
    }

    public static func title(for kind: UnlockRequirement.Kind, state: NagState) -> String {
        switch kind {
        case .completeTasks(let ids):
            let titles = ids.compactMap { state.task($0)?.title }
            switch titles.count {
            case 0: return "Finish the chosen nags"
            case 1: return "Finish “\(titles[0])”"
            case 2: return "Finish “\(titles[0])” and “\(titles[1])”"
            default: return "Finish \(titles.count) nags"
            }
        case .clearDueNags:
            return "Clear every nag that's due"
        case .scanKey(let id):
            return "Scan \(state.key(id)?.name ?? "your key")"
        case .walk(let steps):
            return "Walk \(steps.formatted()) steps"
        case .wait(let minutes):
            return "Wait \(NagFormat.minutes(minutes))"
        case .typePhrase:
            return "Type the commitment phrase"
        }
    }

    static func status(
        of requirement: UnlockRequirement,
        session: LockSession,
        state: NagState,
        steps: Int?,
        now: Date,
        calendar: Calendar
    ) -> RequirementStatus {
        let title = title(for: requirement.kind, state: state)
        func make(_ isMet: Bool, _ detail: String, _ progress: Double? = nil) -> RequirementStatus {
            RequirementStatus(requirement: requirement, isMet: isMet, title: title, detail: detail, progress: progress)
        }

        switch requirement.kind {
        case .completeTasks(let ids):
            let tasks = ids.compactMap { state.task($0) }
            guard !tasks.isEmpty else { return make(true, "Those nags were deleted", 1) }
            let done = tasks.filter { $0.isSatisfied(at: now, calendar: calendar) }.count
            return make(done == tasks.count, "\(done) of \(tasks.count) done", Double(done) / Double(tasks.count))

        case .clearDueNags:
            let due = state.tasks.filter { $0.isOutstanding(at: now) }.count
            return make(due == 0, due == 0 ? "Nothing due" : due == 1 ? "1 nag still due" : "\(due) nags still due")

        case .scanKey(let keyID):
            if session.proofs.contains(requirement.id) { return make(true, "Scanned") }
            return make(false, state.key(keyID) == nil ? "This key was removed" : "Not scanned yet")

        case .walk(let target):
            guard let steps else { return make(false, "Step counting isn't available here", 0) }
            let goal = max(1, target)
            return make(
                steps >= goal,
                "\(min(steps, goal).formatted()) of \(goal.formatted()) steps",
                min(1, Double(steps) / Double(goal))
            )

        case .wait(let minutes):
            guard let requested = session.unlockRequestedAt else {
                return make(false, "Start the timer, then wait it out", 0)
            }
            let total = TimeInterval(minutes * 60)
            let ready = requested.addingTimeInterval(total)
            if ready <= now { return make(true, "Done waiting", 1) }
            let remaining = ready.timeIntervalSince(now)
            return make(false, "\(NagFormat.countdown(remaining)) left", total > 0 ? 1 - remaining / total : 1)

        case .typePhrase:
            let typed = session.proofs.contains(requirement.id)
            return make(typed, typed ? "Typed" : "Not typed yet")
        }
    }

    /// Phrase matching ignores surrounding whitespace and letter case, nothing else.
    public static func phraseMatches(_ input: String, _ phrase: String) -> Bool {
        let normalize = { (text: String) in
            text.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .lowercased()
        }
        return !phrase.isEmpty && normalize(input) == normalize(phrase)
    }
}
