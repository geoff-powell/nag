import Foundation

/// The action decisions shared by widgets and Live Activities.
public struct NagActionAvailability: Hashable, Sendable {
    public var needsKeyScan: Bool
    /// False when `needsKeyScan` is true; action surfaces must offer Scan instead of Done.
    public var canComplete: Bool
    public var canSnooze: Bool

    public static func make(
        task: NagTask,
        state: NagState,
        now: Date,
        calendar: Calendar
    ) -> NagActionAvailability {
        let needsKeyScan = WidgetSnapshot.needsKeyScan(task, in: state)
        return NagActionAvailability(
            needsKeyScan: needsKeyScan,
            canComplete: !needsKeyScan && task.canComplete(at: now, calendar: calendar),
            canSnooze: task.canSnooze(at: now)
        )
    }
}

public struct NagActivityContent: Hashable, Sendable, Codable {
    public var taskID: UUID
    public var title: String
    /// Render with `Text(_, style: .relative)`.
    public var dueAt: Date
    /// Escalating, tone-aware wording supplied by `NagMessages`.
    public var headline: String
    public var canComplete: Bool
    public var canSnooze: Bool
    public var needsKeyScan: Bool
    /// The next instant at which the wording changes. Nil at the top tier.
    public var staleDate: Date?

    public static let maximumDuration: TimeInterval = 8 * 60 * 60

    public static func make(
        task: NagTask,
        state: NagState,
        tone: NagTone,
        now: Date,
        calendar: Calendar = .current
    ) -> NagActivityContent? {
        guard !task.isFinished,
              task.isNagging(at: now),
              !task.isSnoozed(at: now),
              !task.isWorking(at: now)
        else { return nil }

        let overdue = now.timeIntervalSince(task.startAt)
        let tier = NagMessages.tier(overdue: overdue)
        let actions = NagActionAvailability.make(task: task, state: state, now: now, calendar: calendar)
        return NagActivityContent(
            taskID: task.id,
            title: String(task.title.prefix(120)),
            dueAt: task.nagStart ?? task.startAt,
            headline: NagMessages.repeatingBody(
                title: task.title,
                tier: tier,
                tone: task.style.tone ?? tone
            ),
            canComplete: actions.canComplete,
            canSnooze: actions.canSnooze,
            needsKeyScan: actions.needsKeyScan,
            staleDate: NagMessages.nextTierChange(overdue: overdue)
                .map { task.startAt.addingTimeInterval($0) }
        )
    }

    public static func dismissAt(start: Date) -> Date {
        start.addingTimeInterval(maximumDuration)
    }
}

public struct LockActivityContent: Hashable, Sendable, Codable {
    public var profileID: UUID
    public var name: String
    public var symbol: String
    public var openUntil: Date?
    public var waitEndsAt: Date?
    /// Unmet requirement titles, capped to keep ActivityKit content small.
    public var remaining: [String]
    public var staleDate: Date?

    public static let remainingLimit = 4

    public static func make(
        profile: LockProfile,
        state: NagState,
        now: Date,
        calendar: Calendar
    ) -> LockActivityContent? {
        guard profile.isEngaged else { return nil }

        let openUntil = profile.unlockedUntil
        let waitMinutes = profile.requirements.compactMap { requirement -> Int? in
            if case .wait(let minutes) = requirement.kind { return minutes }
            return nil
        }.max()
        let waitEndsAt = profile.session?.unlockRequestedAt.flatMap { requestedAt in
            waitMinutes.map { requestedAt.addingTimeInterval(TimeInterval($0 * 60)) }
        }.flatMap { $0 > now ? $0 : nil }
        let remaining = UnlockEvaluator.evaluate(
            profile,
            state: state,
            steps: nil,
            now: now,
            calendar: calendar
        )
        .filter { !$0.isMet }
        .map(\.title)
        .prefix(remainingLimit)

        return LockActivityContent(
            profileID: profile.id,
            name: String(profile.name.prefix(120)),
            symbol: String(profile.symbol.prefix(80)),
            openUntil: openUntil,
            waitEndsAt: waitEndsAt,
            remaining: Array(remaining),
            staleDate: [openUntil, waitEndsAt, remaining.isEmpty ? nil : now.addingTimeInterval(15 * 60)]
                .compactMap { $0 }
                .filter { $0 > now }
                .min()
        )
    }
}

/// Pure bookkeeping that prevents an activity which reached ActivityKit's eight-hour cap from
/// immediately restarting for the same target. A different (or finished) target clears the cap.
public struct LiveActivityCappedTargets {
    public private(set) var ids: Set<UUID> = []

    public init() {}

    public mutating func select(_ targetID: UUID?) {
        guard let targetID else {
            ids.removeAll()
            return
        }
        ids = ids.filter { $0 == targetID }
    }

    public mutating func recordExpired(_ targetID: UUID) {
        ids.insert(targetID)
    }

    public func allowsStarting(_ targetID: UUID) -> Bool {
        !ids.contains(targetID)
    }
}
