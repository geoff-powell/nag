import Foundation
import Testing
@testable import NagCore

@Suite struct Milestone2Issue16Tests {
    private let calendar = Fixture.calendar
    private let now = Fixture.date(28, 12)

    private static var statusExpectations: [(status: LockStatus, expectedEngaged: Bool)] {
        let session = LockSession(startedAt: Fixture.date(28, 8))
        return [
            (.off, false),
            (.locked(session), true),
            (.unlocked(session, until: Fixture.date(28, 13)), true),
            (.unlocked(session, until: Fixture.date(28, 11)), true),
        ]
    }

    @Test(arguments: statusExpectations)
    func isLockEngagedFollowsLockProfileForEveryStatus(
        status: LockStatus,
        expectedEngaged: Bool
    ) {
        var profile = LockProfile(name: "Focus")
        profile.status = status
        let state = ControlState.make(
            from: NagState(profiles: [profile]),
            lockID: profile.id,
            now: now,
            calendar: calendar
        )
        #expect(state.isLockEngaged == expectedEngaged)
        if case .unlocked(_, let until) = status {
            #expect(state.lock?.isShielding == (until <= now))
        }
    }

    @Test func anOffLockStillReportsItsConfiguredIdentity() {
        var profile = LockProfile(name: "Focus")
        profile.status = .off
        let state = ControlState.make(
            from: NagState(profiles: [profile]),
            lockID: profile.id,
            now: now,
            calendar: calendar
        )
        #expect(state.lock?.id == profile.id)
        #expect(!state.isLockEngaged)
    }

    @Test func aMissingOrDeletedLockIDYieldsNilWithoutTrapping() {
        for lockID in [nil, UUID()] as [UUID?] {
            let value = ControlState.make(from: NagState(), lockID: lockID, now: now, calendar: calendar)
            #expect(value.lock == nil)
            #expect(!value.isLockEngaged)
        }
    }

    @Test func dueCountMatchesWidgetSnapshotAndNagPlan() {
        var finished = task("Done")
        finished.complete(at: now, calendar: calendar)
        let state = NagState(tasks: [task("Due"), task("Later", startAt: Fixture.date(29, 8)), finished])
        let control = ControlState.make(from: state, lockID: nil, now: now, calendar: calendar)
        let widget = WidgetSnapshot.make(from: state, now: now, calendar: calendar)
        let plan = NagPlanner(calendar: calendar).plan(tasks: state.tasks, quietHours: .init(), now: now)
        #expect(control.dueCount == widget.dueCount)
        #expect(control.dueCount == plan.outstandingCount)
    }

    @Test(arguments: statusExpectations.map(\.status))
    func lockNowFromAnyStatusAlwaysProducesAnEngagedLockedProfile(status: LockStatus) throws {
        let (profile, value) = try lockNow(from: status)
        guard case .locked = profile.status else {
            Issue.record("lockNow must always produce a locked status")
            return
        }
        #expect(profile.isLocked)
        #expect(value.isLockEngaged)
    }

    @Test func lockSummaryInControlStateMatchesTheWidgetOne() {
        var profile = LockProfile(name: "Focus", symbol: "moon.fill")
        profile.status = .locked(LockSession(startedAt: Fixture.date(28, 8)))
        let state = NagState(profiles: [profile])
        let widget = WidgetSnapshot.make(from: state, now: now, calendar: calendar)
        let control = ControlState.make(from: state, lockID: profile.id, now: now, calendar: calendar)
        #expect(control.lock == widget.locks.first)
    }

    @Test func intentsContainNoLockDisengagementCalls() throws {
        let sources = try swiftSources(in: repositoryRoot().appending(path: "NagIntents"))
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        #expect(!sources.contains("grantUnlock"))
        #expect(!sources.contains("emergencyUnlock"))
        #expect(!sources.contains("relockNow"))
    }

    @Test func nagActionsAPIContainsNoUnlockPath() throws {
        let source = try String(
            contentsOf: repositoryRoot().appending(path: "Packages/NagKit/Sources/NagCore/NagActions.swift"),
            encoding: .utf8
        )
        #expect(!source.contains("func grantUnlock"))
        #expect(!source.contains("func emergencyUnlock"))
        #expect(!source.contains("func relockNow"))
    }

    @Test func relockingAnUnlockedProfileDoesNotExtendTheUnlockWindow() throws {
        let session = LockSession(startedAt: Fixture.date(28, 8))
        let (profile, _) = try lockNow(from: .unlocked(session, until: Fixture.date(28, 13)))
        #expect(profile.unlockedUntil == nil)
    }

    @Test func aDeletedLockProducesNoSuchLockRatherThanATrap() {
        let store = store(containing: NagState())
        #expect(throws: NagActions.Failure.noSuchLock) {
            try NagActions.lockNow(profileID: UUID(), store: store, now: now, calendar: calendar)
        }
    }

    private func task(_ title: String, startAt: Date? = nil) -> NagTask {
        NagTask(title: title, startAt: startAt ?? Fixture.date(28, 8), now: Fixture.date(28, 7))
    }

    private func lockNow(from status: LockStatus) throws -> (LockProfile, ControlState) {
        var profile = LockProfile(name: "Focus")
        profile.status = status
        let store = store(containing: NagState(profiles: [profile]))
        let result = try NagActions.lockNow(profileID: profile.id, store: store, now: now, calendar: calendar)
        return (
            result,
            ControlState.make(from: store.load(), lockID: profile.id, now: now, calendar: calendar)
        )
    }

    private func store(containing state: NagState) -> SharedStore {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let store = SharedStore(directory: directory)
        store.update { $0 = state }
        return store
    }

    private func repositoryRoot() -> URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: candidate.appending(path: "NagIntents").path) {
            candidate.deleteLastPathComponent()
        }
        return candidate
    }

    private func swiftSources(in directory: URL) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return contents.filter { $0.pathExtension == "swift" }
    }
}
