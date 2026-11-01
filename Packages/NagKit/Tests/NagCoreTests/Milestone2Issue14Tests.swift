import Foundation
import Testing
@testable import NagCore

@Suite struct Milestone2Issue14Tests {
    let calendar = Fixture.calendar
    let now = Fixture.date(28, 12)

    private func task(_ title: String, at date: Date? = nil) -> NagTask {
        NagTask(title: title, startAt: date ?? Fixture.date(28, 8), now: Fixture.date(28, 7))
    }

    private func lockedProfile(
        _ name: String,
        requirements: [UnlockRequirement] = [],
        requestedAt: Date? = nil
    ) -> LockProfile {
        var profile = LockProfile(name: name, requirements: requirements)
        var session = LockSession(startedAt: Fixture.date(28, 8))
        session.unlockRequestedAt = requestedAt
        profile.status = .locked(session)
        return profile
    }

    @Test func countsOrdersAndCapsDueNags() {
        let tasks = (0..<8).map { task("Nag \($0)", at: Fixture.date(28, $0 + 1)) }
        let snapshot = WidgetSnapshot.make(from: NagState(tasks: tasks), now: now, calendar: calendar, limit: 4)
        #expect(snapshot.dueCount == 8)
        #expect(snapshot.due.count == 4)
        #expect(snapshot.due.map(\.title) == ["Nag 0", "Nag 1", "Nag 2", "Nag 3"])
    }

    @Test func excludesFinishedAndNotYetStartedNags() {
        var finished = task("Finished")
        finished.complete(at: Fixture.date(28, 9), calendar: calendar)
        let future = task("Future", at: Fixture.date(28, 13))
        let snapshot = WidgetSnapshot.make(from: NagState(tasks: [finished, future]), now: now, calendar: calendar)
        #expect(snapshot.due.isEmpty)
        #expect(snapshot.nextChange == Fixture.date(28, 13))
    }

    @Test func snoozedNagsSortAfterUnsnoozedOnes() {
        var snoozed = task("Snoozed", at: Fixture.date(28, 6))
        snoozed.snoozedUntil = Fixture.date(28, 13)
        let due = task("Due", at: Fixture.date(28, 10))
        let snapshot = WidgetSnapshot.make(from: NagState(tasks: [snoozed, due]), now: now, calendar: calendar)
        #expect(snapshot.due.map(\.title) == ["Due", "Snoozed"])
    }

    @Test func oldestOverduePicksEarliestNagStartNotEarliestStartAt() {
        var earlyButSnoozed = task("Snoozed", at: Fixture.date(28, 6))
        earlyButSnoozed.snoozedUntil = Fixture.date(28, 11)
        let laterStart = task("Later start", at: Fixture.date(28, 9))
        let snapshot = WidgetSnapshot.make(from: NagState(tasks: [earlyButSnoozed, laterStart]), now: now, calendar: calendar)
        #expect(snapshot.oldestOverdue?.title == "Later start")
    }

    @Test func oldestOverdueIgnoresTheCap() {
        let oldest = task("Oldest", at: Fixture.date(28, 5))
        let state = NagState(tasks: [task("Newer", at: Fixture.date(28, 10)), oldest])
        let snapshot = WidgetSnapshot.make(from: state, now: now, calendar: calendar, limit: 0)
        #expect(snapshot.due.isEmpty)
        #expect(snapshot.oldestOverdue?.title == "Oldest")
    }

    @Test func needsKeyScanIsTrueOnlyWhenTheKeyStillExists() {
        let key = UnlockKey(name: "Bottle", kind: .code, fingerprint: "key")
        let present = taskWithProof(.scanKey(key.id))
        let deleted = taskWithProof(.scanKey(UUID()))
        let state = NagState(tasks: [present, deleted], keys: [key])
        let summaries = WidgetSnapshot.make(from: state, now: now, calendar: calendar).due
        #expect(summaries.first { $0.id == present.id }?.needsKeyScan == true)
        #expect(summaries.first { $0.id == deleted.id }?.needsKeyScan == false)
    }

    @Test func canSnoozeIsFalseOnceMaxSnoozesIsReached() {
        var nag = task("No more")
        nag.style.maxSnoozes = 1
        nag.snoozeCount = 1
        let summary = WidgetSnapshot.make(from: NagState(tasks: [nag]), now: now, calendar: calendar).due[0]
        #expect(!summary.canSnooze)
    }

    @Test func canCompleteFollowsTaskRulesForRepeatingAndOneOff() {
        let oneOff = task("One off")
        let repeating = NagTask(title: "Daily", startAt: Fixture.date(29, 8), repeatRule: .daily)
        let state = NagState(tasks: [oneOff, repeating])
        let snapshot = WidgetSnapshot.make(from: state, now: now, calendar: calendar)
        #expect(snapshot.due[0].canComplete == oneOff.canComplete(at: now, calendar: calendar))
        #expect(!repeating.canComplete(at: now, calendar: calendar))
    }

    @Test func nextChangeIsTheEarliestPendingBoundary() {
        var snoozed = task("Snoozed")
        snoozed.snoozedUntil = Fixture.date(28, 14)
        var working = task("Working")
        working.startedAt = Fixture.date(28, 11, 30)
        working.style.workMinutes = 60
        var unlocked = LockProfile(name: "Open")
        unlocked.status = .unlocked(LockSession(startedAt: Fixture.date(28, 8)), until: Fixture.date(28, 12, 45))
        let waiting = lockedProfile("Wait", requirements: [.init(kind: .wait(minutes: 20))], requestedAt: Fixture.date(28, 12, 10))
        let future = task("Future", at: Fixture.date(28, 13))
        let state = NagState(tasks: [snoozed, working, future], profiles: [unlocked, waiting])
        #expect(WidgetSnapshot.make(from: state, now: now, calendar: calendar).nextChange == Fixture.date(28, 12, 30))
    }

    @Test func eachPendingBoundaryCanDriveNextChange() {
        let future = task("Future", at: Fixture.date(28, 13))
        #expect(snapshot(tasks: [future]).nextChange == Fixture.date(28, 13))
        var snoozed = task("Snoozed"); snoozed.snoozedUntil = Fixture.date(28, 13)
        #expect(snapshot(tasks: [snoozed]).nextChange == Fixture.date(28, 13))
        var working = task("Working"); working.startedAt = Fixture.date(28, 11); working.style.workMinutes = 120
        #expect(snapshot(tasks: [working]).nextChange == Fixture.date(28, 13))
        var unlocked = LockProfile(name: "Open")
        unlocked.status = .unlocked(LockSession(startedAt: Fixture.date(28, 8)), until: Fixture.date(28, 13))
        #expect(snapshot(profiles: [unlocked]).nextChange == Fixture.date(28, 13))
        let wait = lockedProfile("Wait", requirements: [.init(kind: .wait(minutes: 60))], requestedAt: Fixture.date(28, 12))
        #expect(snapshot(profiles: [wait]).nextChange == Fixture.date(28, 13))
    }

    @Test func nextChangeIsNilWhenNothingIsPending() {
        #expect(snapshot(tasks: [task("Overdue")]).nextChange == nil)
    }

    @Test func lockSummaryOpenUntilOnlyForUnlocked() {
        let off = LockProfile(name: "Off")
        let locked = lockedProfile("Locked")
        var open = LockProfile(name: "Open")
        open.status = .unlocked(LockSession(startedAt: Fixture.date(28, 8)), until: Fixture.date(28, 13))
        let summaries = snapshot(profiles: [off, locked, open]).locks
        #expect(summaries.first { $0.name == "Locked" }?.openUntil == nil)
        #expect(summaries.first { $0.name == "Open" }?.openUntil == Fixture.date(28, 13))
        #expect(!summaries.contains { $0.name == "Off" })
    }

    @Test func lockSummaryWaitEndsAtOnlyWhenTheTimerIsRunning() {
        let stopped = lockedProfile("Stopped", requirements: [.init(kind: .wait(minutes: 15))])
        let running = lockedProfile("Running", requirements: [.init(kind: .wait(minutes: 15))], requestedAt: now)
        let summaries = snapshot(profiles: [stopped, running]).locks
        #expect(summaries.first { $0.name == "Stopped" }?.waitEndsAt == nil)
        #expect(summaries.first { $0.name == "Running" }?.waitEndsAt == now.addingTimeInterval(900))
    }

    @Test func lockSummaryWaitEndsAtUsesTheLongestWait() {
        let waits = [
            UnlockRequirement(kind: .wait(minutes: 10)),
            UnlockRequirement(kind: .wait(minutes: 45)),
        ]
        let running = lockedProfile("Running", requirements: waits, requestedAt: now)

        #expect(snapshot(profiles: [running]).locks[0].waitEndsAt == now.addingTimeInterval(45 * 60))
    }

    @Test func finishedTaskTimersDoNotDriveNextChange() {
        var finished = task("Finished")
        finished.snoozedUntil = Fixture.date(28, 13)
        finished.startedAt = Fixture.date(28, 11)
        finished.style.workMinutes = 120
        finished.complete(at: Fixture.date(28, 11, 30), calendar: calendar)

        #expect(snapshot(tasks: [finished]).nextChange == nil)
    }

    @Test func locksContainsEveryEngagedProfileAndNoOffOnes() {
        let snapshot = snapshot(profiles: [LockProfile(name: "Off"), lockedProfile("One"), lockedProfile("Two")])
        #expect(snapshot.locks.map(\.name).sorted() == ["One", "Two"])
    }

    @Test func dueCountMatchesNagPlanOutstandingCount() {
        var done = task("Done"); done.complete(at: now, calendar: calendar)
        let state = NagState(tasks: [task("Due"), task("Future", at: Fixture.date(29, 8)), done])
        let expected = NagPlanner(calendar: calendar).plan(tasks: state.tasks, quietHours: .init(), now: now).outstandingCount
        #expect(snapshot(tasks: state.tasks).dueCount == expected)
    }

    @Test func twoHundredNagsSnapshotStaysSmallAndFast() {
        let snapshot = snapshot(tasks: (0..<200).map { task("Nag \($0)") })
        #expect(snapshot.dueCount == 200)
        #expect(snapshot.due.count == 4)
        #expect(snapshot.locks.isEmpty)
    }

    @Test func sampleIsStableAndNonEmpty() {
        let date = Fixture.date(28, 12)
        #expect(WidgetSnapshot.sample(now: date) == WidgetSnapshot.sample(now: date))
        #expect(!WidgetSnapshot.sample(now: date).due.isEmpty)
        #expect(!WidgetSnapshot.sample(now: date).locks.isEmpty)
    }

    @Test func scanRowsNeverOfferComplete() throws {
        let key = UnlockKey(name: "Key", kind: .code, fingerprint: "proof")
        let nag = taskWithProof(.scanKey(key.id))
        let state = NagState(tasks: [nag], keys: [key])
        #expect(snapshot(state).due[0].needsKeyScan)
        let store = try store(containing: state)
        #expect(throws: NagActions.Failure.needsKeyScan(taskID: nag.id, keyName: key.name)) {
            try NagActions.complete(taskID: nag.id, store: store, now: now, calendar: calendar)
        }
    }

    @Test func widgetRowCapNeverExceedsFamilyCapacity() {
        #expect(snapshot(tasks: (0..<10).map { task("\($0)") }).due.count <= 4)
    }

    @Test func dueCountIsZeroAndOldestOverdueIsNilForAnEmptyState() {
        let snapshot = snapshot(NagState())
        #expect(snapshot.dueCount == 0)
        #expect(snapshot.oldestOverdue == nil)
    }

    @Test func oldestOverdueIsNilWhenEverythingDueIsStillSnoozed() {
        var nag = task("Snoozed"); nag.snoozedUntil = Fixture.date(28, 13)
        let snapshot = snapshot(tasks: [nag])
        #expect(snapshot.dueCount == 1)
        #expect(snapshot.oldestOverdue == nil)
        #expect(snapshot.nextChange == Fixture.date(28, 13))
    }

    @Test func nextChangeIsTheSnoozeExpiryWhenEverythingIsSnoozed() {
        var first = task("First"); first.snoozedUntil = Fixture.date(28, 13)
        var second = task("Second"); second.snoozedUntil = Fixture.date(28, 14)
        #expect(snapshot(tasks: [first, second]).nextChange == Fixture.date(28, 13))
    }

    @Test func locksShowEveryEngagedProfileIncludingTemporarilyUnlockedOnes() {
        var open = LockProfile(name: "Open")
        open.status = .unlocked(LockSession(startedAt: Fixture.date(28, 8)), until: Fixture.date(28, 13))
        let summary = snapshot(profiles: [lockedProfile("Locked"), open]).locks.first { $0.name == "Open" }
        #expect(summary?.isShielding == false)
        #expect(summary?.openUntil == Fixture.date(28, 13))
    }

    @Test func shieldingLocksSortBeforeTemporarilyOpenOnes() {
        var open = LockProfile(name: "A Open")
        open.status = .unlocked(LockSession(startedAt: Fixture.date(28, 8)), until: Fixture.date(28, 13))
        #expect(snapshot(profiles: [open, lockedProfile("Z Locked")]).locks.map(\.name) == ["Z Locked", "A Open"])
    }

    @Test func offProfilesNeverAppear() {
        #expect(snapshot(profiles: [LockProfile(name: "Off")]).locks.isEmpty)
    }

    @Test func stepsRemainingCountsOnlyUnmetRequirements() {
        let requirement = UnlockRequirement(kind: .typePhrase("yes"))
        var profile = lockedProfile("Mixed", requirements: [requirement, .init(kind: .clearDueNags)])
        if case .locked(var session) = profile.status {
            session.proofs.insert(requirement.id)
            profile.status = .locked(session)
        }
        let state = NagState(tasks: [task("Due")], profiles: [profile])
        let expected = UnlockEvaluator.evaluate(profile, state: state, steps: nil, now: now, calendar: calendar).filter { !$0.isMet }.count
        #expect(snapshot(state).locks[0].stepsRemaining == expected)
    }

    @Test func stepsRemainingIsZeroForARequirementlessLock() {
        #expect(snapshot(profiles: [lockedProfile("Empty")]).locks[0].stepsRemaining == 0)
    }

    private func taskWithProof(_ proof: CompletionProof) -> NagTask {
        NagTask(title: "Proof", startAt: Fixture.date(28, 8), proof: proof, now: Fixture.date(28, 7))
    }

    private func snapshot(_ state: NagState) -> WidgetSnapshot {
        WidgetSnapshot.make(from: state, now: now, calendar: calendar)
    }

    private func snapshot(tasks: [NagTask] = [], profiles: [LockProfile] = []) -> WidgetSnapshot {
        snapshot(NagState(tasks: tasks, profiles: profiles))
    }

    private func store(containing state: NagState) throws -> SharedStore {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = SharedStore(directory: directory)
        store.update { $0 = state }
        return store
    }
}
