import Foundation
import Testing
@testable import NagCore

@Suite struct Milestone2Issue17Tests {
    let calendar = Fixture.calendar
    let now = Fixture.date(28, 12)

    enum SuppressedNag: CaseIterable, Sendable {
        case notYetDue
        case finished
        case snoozed
        case working
    }

    private func task(_ title: String = "Take medication", overdue: TimeInterval = 60) -> NagTask {
        NagTask(title: title, startAt: now.addingTimeInterval(-overdue), now: Fixture.date(28, 7))
    }

    private func content(_ task: NagTask, state: NagState? = nil, tone: NagTone = .standard) -> NagActivityContent? {
        let state = state ?? NagState(tasks: [task])
        return NagActivityContent.make(task: task, state: state, tone: tone, now: now, calendar: calendar)
    }

    @Test(arguments: SuppressedNag.allCases)
    func makeReturnsNilForNagsThatShouldNotHaveAnActivity(_ kind: SuppressedNag) {
        var nag = task()
        switch kind {
        case .notYetDue:
            nag.startAt = now.addingTimeInterval(60)
        case .finished:
            nag.complete(at: now.addingTimeInterval(-30), calendar: calendar)
        case .snoozed:
            nag.snoozedUntil = now.addingTimeInterval(60)
        case .working:
            nag.startedAt = now.addingTimeInterval(-60)
        }
        #expect(content(nag) == nil)
    }

    @Test func headlineEscalatesAcrossAllFourTiers() throws {
        let overdueValues: [TimeInterval] = [0, 16 * 60, 61 * 60, 4 * 60 * 60]
        let contents = try overdueValues.map { overdue in
            try #require(content(task(overdue: overdue)))
        }
        #expect(Set(contents.map(\.headline)).count == 4)
        for (overdue, result) in zip(overdueValues, contents) {
            #expect(result.headline == NagMessages.repeatingBody(
                title: result.title,
                tier: NagMessages.tier(overdue: overdue),
                tone: .standard
            ))
        }
    }

    @Test func headlineDiffersPerTone() throws {
        let nag = task(overdue: 16 * 60)
        let headlines = try NagTone.allCases.map { try #require(content(nag, tone: $0)).headline }
        #expect(Set(headlines).count == 3)
    }

    @Test func perNagToneOverridesTheAppDefault() throws {
        var nag = task(overdue: 16 * 60)
        nag.style.tone = .pushy
        let result = try #require(content(nag, tone: .gentle))
        #expect(result.headline == NagMessages.repeatingBody(title: nag.title, tier: 1, tone: .pushy))
    }

    @Test func staleDateIsTheNextTierBoundaryAndNilAtTheTopTier() throws {
        let cases: [(TimeInterval, TimeInterval?)] = [
            (0, 15 * 60),
            (16 * 60, 60 * 60),
            (61 * 60, 3 * 60 * 60),
            (4 * 60 * 60, nil),
        ]
        for (overdue, boundary) in cases {
            let nag = task(overdue: overdue)
            let result = try #require(content(nag))
            #expect(result.staleDate == boundary.map { nag.startAt.addingTimeInterval($0) })
        }
    }

    @Test func needsKeyScanAndCanSnoozeMirrorTheWidgetRules() throws {
        let key = UnlockKey(name: "Bottle", kind: .code, fingerprint: "proof")
        var nag = task()
        nag.proof = .scanKey(key.id)
        let state = NagState(tasks: [nag], keys: [key])
        let summary = try #require(WidgetSnapshot.make(from: state, now: now, calendar: calendar).oldestOverdue)
        let result = try #require(content(nag, state: state))
        #expect(result.needsKeyScan == summary.needsKeyScan)
        #expect(result.canSnooze == summary.canSnooze)
    }

    @Test func lockActivityIsNilForOffLocks() {
        let profile = LockProfile(name: "Focus")
        #expect(LockActivityContent.make(profile: profile, state: NagState(), now: now, calendar: calendar) == nil)
    }

    @Test func openUntilIsSetOnlyForUnlockedLocks() throws {
        var locked = LockProfile(name: "Locked")
        locked.status = .locked(LockSession(startedAt: now.addingTimeInterval(-600)))
        var unlocked = LockProfile(name: "Open")
        let until = now.addingTimeInterval(600)
        unlocked.status = .unlocked(LockSession(startedAt: now.addingTimeInterval(-600)), until: until)
        #expect(try #require(lockContent(locked)).openUntil == nil)
        #expect(try #require(lockContent(unlocked)).openUntil == until)
    }

    @Test func waitEndsAtIsSetOnlyWhenTheTimerIsRunning() throws {
        let requirement = UnlockRequirement(kind: .wait(minutes: 15))
        var stopped = LockProfile(name: "Stopped", requirements: [requirement])
        stopped.status = .locked(LockSession(startedAt: now.addingTimeInterval(-600)))
        var running = stopped
        var session = LockSession(startedAt: now.addingTimeInterval(-600))
        session.unlockRequestedAt = now
        running.status = .locked(session)
        #expect(try #require(lockContent(stopped)).waitEndsAt == nil)
        #expect(try #require(lockContent(running)).waitEndsAt == now.addingTimeInterval(15 * 60))

        session.unlockRequestedAt = now.addingTimeInterval(-20 * 60)
        running.status = .locked(session)
        #expect(try #require(lockContent(running)).waitEndsAt == nil)
    }

    @Test func remainingIsCappedAndListsOnlyUnmetRequirements() throws {
        let met = UnlockRequirement(kind: .typePhrase("done"))
        let unmet = (0..<10).map { _ in UnlockRequirement(kind: .typePhrase("not done")) }
        var profile = LockProfile(name: "Focus", requirements: [met] + unmet)
        var session = LockSession(startedAt: now.addingTimeInterval(-600))
        session.proofs.insert(met.id)
        profile.status = .locked(session)
        let result = try #require(lockContent(profile))
        #expect(result.remaining.count == LockActivityContent.remainingLimit)
        #expect(result.remaining.allSatisfy { $0 == "Type the commitment phrase" })
    }

    @Test func worstCaseContentStateStaysUnderFourKilobytes() throws {
        let longTitle = String(repeating: "Medication reminder ", count: 20)
        let nag = task(longTitle, overdue: 4 * 60 * 60)
        let nagContent = try #require(content(nag))

        let requiredTasks = (0..<10).map { task(String(repeating: "Long requirement title ", count: 10) + "\($0)") }
        let requirements = requiredTasks.map { UnlockRequirement(kind: .completeTasks([$0.id])) }
        var profile = LockProfile(name: String(repeating: "Focus ", count: 30), requirements: requirements)
        profile.status = .locked(LockSession(startedAt: now.addingTimeInterval(-600)))
        let state = NagState(tasks: requiredTasks, profiles: [profile])
        let lockContent = try #require(LockActivityContent.make(
            profile: profile,
            state: state,
            now: now,
            calendar: calendar
        ))
        struct NagAttributes: Codable { let taskID: UUID; let title: String; let startedAt: Date }
        struct NagContentState: Codable { let content: NagActivityContent }
        struct LockAttributes: Codable { let profileID: UUID; let name: String; let startedAt: Date }
        struct LockContentState: Codable { let content: LockActivityContent }
        let encoder = JSONEncoder()
        let nagSize = try encoder.encode(NagAttributes(
            taskID: nagContent.taskID,
            title: nagContent.title,
            startedAt: now
        )).count + encoder.encode(NagContentState(content: nagContent)).count
        let lockSize = try encoder.encode(LockAttributes(
            profileID: lockContent.profileID,
            name: lockContent.name,
            startedAt: now
        )).count + encoder.encode(LockContentState(content: lockContent)).count
        #expect(nagSize < 4096)
        #expect(lockSize < 4096)
    }

    @Test func dismissAtIsEightHoursAfterTheStart() {
        #expect(NagActivityContent.maximumDuration == 8 * 60 * 60)
        #expect(NagActivityContent.dismissAt(start: now) == now.addingTimeInterval(8 * 60 * 60))
    }

    @Test func liveActivitiesAreOffByDefault() {
        #expect(!AppSettings().liveActivitiesEnabled)
    }

    @Test func settingsDecodedFromJsonWithoutTheKeyDefaultToOff() throws {
        let data = Data(#"{"settings":{"nagTone":"standard"}}"#.utf8)
        let state = try JSONDecoder().decode(NagState.self, from: data)
        #expect(!state.settings.liveActivitiesEnabled)
        #expect(state.settings.quietHours == QuietHours())
        #expect(state.settings.emergencyUnlocksPerMonth == 3)
        #expect(state.settings.emergencyUnlocksUsed.isEmpty)
        #expect(!state.settings.hasOnboarded)
        #expect(!state.settings.screenTimeApproved)
    }

    @Test func settingsRoundTripThroughJsonPreservesTheFlag() throws {
        let original = NagState(settings: AppSettings(liveActivitiesEnabled: true))
        let decoded = try JSONDecoder().decode(NagState.self, from: JSONEncoder().encode(original))
        #expect(decoded.settings.liveActivitiesEnabled)
    }

    @Test func addingTheFlagDoesNotBreakNagStateEquality() {
        let disabled = NagState(settings: AppSettings(liveActivitiesEnabled: false))
        let enabled = NagState(settings: AppSettings(liveActivitiesEnabled: true))
        #expect(disabled != enabled)
    }

    @Test func theActionMatrixIsIdenticalForWidgetsAndActivities() throws {
        let key = UnlockKey(name: "Key", kind: .code, fingerprint: "proof")
        let plain = task("Plain")
        var keyPresent = task("Key present")
        keyPresent.proof = .scanKey(key.id)
        var keyMissing = task("Key missing")
        keyMissing.proof = .scanKey(UUID())
        var noSnoozes = task("No snoozes")
        noSnoozes.style.maxSnoozes = 0
        var completed = task("Completed")
        completed.complete(at: now, calendar: calendar)
        let state = NagState(tasks: [plain, keyPresent, keyMissing, noSnoozes, completed], keys: [key])
        let summaries = WidgetSnapshot.make(from: state, now: now, calendar: calendar, limit: 10).due

        let cases: [(NagTask, (needsKeyScan: Bool, canComplete: Bool, canSnooze: Bool))] = [
            (plain, (false, true, true)),
            (keyPresent, (true, false, true)),
            (keyMissing, (false, true, true)),
            (noSnoozes, (false, true, false)),
        ]
        for (nag, expected) in cases {
            let summary = try #require(summaries.first { $0.id == nag.id })
            let activity = try #require(NagActivityContent.make(
                task: nag,
                state: state,
                tone: .standard,
                now: now,
                calendar: calendar
            ))
            #expect((summary.needsKeyScan, summary.canComplete, summary.canSnooze) == expected)
            #expect((activity.needsKeyScan, activity.canComplete, activity.canSnooze) == expected)
        }
        #expect(summaries.contains { $0.id == completed.id } == false)
        #expect(content(completed, state: state) == nil)
    }

    @Test func keyScanNagCannotExposeCompleteAction() throws {
        let key = UnlockKey(name: "Key", kind: .code, fingerprint: "proof")
        var nag = task()
        nag.proof = .scanKey(key.id)
        let state = NagState(tasks: [nag], keys: [key])
        let summary = try #require(WidgetSnapshot.make(from: state, now: now, calendar: calendar).oldestOverdue)
        #expect(summary.needsKeyScan)
        #expect(!summary.canComplete)
        #expect(!(try #require(content(nag, state: state))).canComplete)
    }

    @Test func cappedTargetIsNotRestartedUntilTheTargetChangesOrFinishes() {
        let first = UUID()
        let second = UUID()
        var capped = LiveActivityCappedTargets()
        capped.select(first)
        capped.recordExpired(first)
        #expect(!capped.allowsStarting(first))
        capped.select(second)
        #expect(capped.allowsStarting(second))
        capped.select(nil)
        capped.select(first)
        #expect(capped.allowsStarting(first))
    }

    private func lockContent(_ profile: LockProfile) -> LockActivityContent? {
        LockActivityContent.make(
            profile: profile,
            state: NagState(profiles: [profile]),
            now: now,
            calendar: calendar
        )
    }
}
