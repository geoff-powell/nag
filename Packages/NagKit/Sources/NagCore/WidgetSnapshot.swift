import Foundation

public struct NagSummary: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var dueAt: Date
    public var isOverdue: Bool
    public var isSnoozed: Bool
    public var isStarted: Bool
    public var canComplete: Bool
    public var canSnooze: Bool
    public var needsKeyScan: Bool

    public init(
        id: UUID,
        title: String,
        dueAt: Date,
        isOverdue: Bool,
        isSnoozed: Bool,
        isStarted: Bool,
        canComplete: Bool,
        canSnooze: Bool,
        needsKeyScan: Bool
    ) {
        self.id = id
        self.title = title
        self.dueAt = dueAt
        self.isOverdue = isOverdue
        self.isSnoozed = isSnoozed
        self.isStarted = isStarted
        self.canComplete = canComplete
        self.canSnooze = canSnooze
        self.needsKeyScan = needsKeyScan
    }
}

public struct LockSummary: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var isShielding: Bool
    public var openUntil: Date?
    public var waitEndsAt: Date?
    public var stepsRemaining: Int

    public init(
        id: UUID,
        name: String,
        symbol: String,
        isShielding: Bool,
        openUntil: Date?,
        waitEndsAt: Date?,
        stepsRemaining: Int
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.isShielding = isShielding
        self.openUntil = openUntil
        self.waitEndsAt = waitEndsAt
        self.stepsRemaining = stepsRemaining
    }
}

public struct WidgetSnapshot: Hashable, Sendable {
    public var dueCount: Int
    public var oldestOverdue: NagSummary?
    public var due: [NagSummary]
    public var locks: [LockSummary]
    public var nextChange: Date?

    public init(
        dueCount: Int,
        oldestOverdue: NagSummary?,
        due: [NagSummary],
        locks: [LockSummary],
        nextChange: Date?
    ) {
        self.dueCount = dueCount
        self.oldestOverdue = oldestOverdue
        self.due = due
        self.locks = locks
        self.nextChange = nextChange
    }

    public static func needsKeyScan(_ task: NagTask, in state: NagState) -> Bool {
        task.proof.keyID.flatMap(state.key) != nil
    }

    public static func make(
        from state: NagState,
        now: Date,
        calendar: Calendar,
        limit: Int = 4
    ) -> WidgetSnapshot {
        var allDue: [NagSummary] = []
        allDue.reserveCapacity(state.tasks.count)
        var nextChange: Date?

        func consider(_ date: Date?) {
            guard let date, date > now, date < (nextChange ?? .distantFuture) else { return }
            nextChange = date
        }

        for task in state.tasks {
            guard !task.isFinished else { continue }
            let nagStart = task.nagStart
            if !task.isOutstanding(at: now) { consider(nagStart) }
            consider(task.snoozedUntil)
            consider(task.workingUntil())

            guard task.isOutstanding(at: now) else { continue }
            allDue.append(NagSummary(
                id: task.id,
                title: task.title,
                dueAt: nagStart ?? task.startAt,
                isOverdue: task.isNagging(at: now),
                isSnoozed: task.isSnoozed(at: now),
                isStarted: task.isStarted(at: now),
                canComplete: task.canComplete(at: now, calendar: calendar),
                canSnooze: task.canSnooze(at: now),
                needsKeyScan: needsKeyScan(task, in: state)
            ))
        }

        allDue.sort {
            if $0.isSnoozed != $1.isSnoozed { return !$0.isSnoozed }
            if $0.dueAt != $1.dueAt { return $0.dueAt < $1.dueAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let oldestOverdue = allDue.first(where: \.isOverdue)
        let visibleDue = allDue.prefix(max(0, limit))

        var locks: [LockSummary] = []
        locks.reserveCapacity(state.profiles.count)
        for profile in state.profiles where profile.isEngaged {
            let waitMinutes = profile.requirements.compactMap { requirement -> Int? in
                if case .wait(let minutes) = requirement.kind { return minutes }
                return nil
            }.max()
            let waitEndsAt = profile.session?.unlockRequestedAt.flatMap { requested in
                waitMinutes.map { requested.addingTimeInterval(TimeInterval($0 * 60)) }
            }
            let openUntil = profile.unlockedUntil
            consider(openUntil)
            consider(waitEndsAt)
            let stepsRemaining = UnlockEvaluator.evaluate(
                profile,
                state: state,
                steps: nil,
                now: now,
                calendar: calendar
            ).filter { !$0.isMet }.count
            locks.append(LockSummary(
                id: profile.id,
                name: profile.name,
                symbol: profile.symbol,
                isShielding: profile.isShielding(at: now),
                openUntil: openUntil,
                waitEndsAt: waitEndsAt,
                stepsRemaining: stepsRemaining
            ))
        }
        locks.sort {
            if $0.isShielding != $1.isShielding { return $0.isShielding }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }

        return WidgetSnapshot(
            dueCount: allDue.count,
            oldestOverdue: oldestOverdue,
            due: Array(visibleDue),
            locks: locks,
            nextChange: nextChange
        )
    }

    public static func sample(now: Date = .now) -> WidgetSnapshot {
        let due = NagSummary(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            title: "Take medication",
            dueAt: now.addingTimeInterval(-25 * 60),
            isOverdue: true,
            isSnoozed: false,
            isStarted: false,
            canComplete: true,
            canSnooze: true,
            needsKeyScan: false
        )
        let lock = LockSummary(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            name: "Focus",
            symbol: "lock.fill",
            isShielding: true,
            openUntil: nil,
            waitEndsAt: nil,
            stepsRemaining: 2
        )
        return WidgetSnapshot(dueCount: 1, oldestOverdue: due, due: [due], locks: [lock], nextChange: nil)
    }
}
