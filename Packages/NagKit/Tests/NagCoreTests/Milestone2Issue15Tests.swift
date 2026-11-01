import Foundation
import Testing
@testable import NagCore

@Suite struct Milestone2Issue15Tests {
    private let calendar = Fixture.calendar
    private let now = Fixture.date(28, 10)

    private func store(containing state: NagState = NagState()) -> SharedStore {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let store = SharedStore(directory: directory)
        store.update { $0 = state }
        return store
    }

    private func stateData(in store: SharedStore) throws -> Data {
        try Data(contentsOf: store.directory.appending(path: "state.json"))
    }

    @Test func completeThrowsNeedsKeyScanAndLeavesTheStoreUntouched() throws {
        let key = UnlockKey(name: "Medicine cabinet", kind: .code, fingerprint: "fingerprint")
        let task = NagTask(title: "Take medicine", startAt: now, proof: .scanKey(key.id), now: now)
        let original = NagState(tasks: [task], keys: [key])
        let store = store(containing: original)
        let bytesBefore = try stateData(in: store)

        #expect(throws: NagActions.Failure.needsKeyScan(taskID: task.id, keyName: key.name)) {
            try NagActions.complete(taskID: task.id, store: store, now: now, calendar: calendar)
        }
        #expect(store.load() == original)
        #expect(try stateData(in: store) == bytesBefore)
    }

    @Test func completeFallsBackToPlainDoneWhenTheKeyWasDeleted() throws {
        let task = NagTask(title: "Take medicine", startAt: now, proof: .scanKey(UUID()), now: now)
        let store = store(containing: NagState(tasks: [task]))

        let completed = try NagActions.complete(taskID: task.id, store: store, now: now, calendar: calendar)

        #expect(completed.completedAt == now)
        #expect(store.load().task(task.id) == completed)
    }

    @Test func completeHonoursCanCompleteForRepeatingAndOneOff() throws {
        var finished = NagTask(title: "Finished", startAt: now, now: now)
        finished.complete(at: now, calendar: calendar)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let futureRepeating = NagTask(title: "Tomorrow", startAt: tomorrow, repeatRule: .daily, now: now)
        let original = NagState(tasks: [finished, futureRepeating])
        let store = store(containing: original)

        #expect(throws: NagActions.Failure.cannotComplete) {
            try NagActions.complete(taskID: finished.id, store: store, now: now, calendar: calendar)
        }
        #expect(throws: NagActions.Failure.cannotComplete) {
            try NagActions.complete(taskID: futureRepeating.id, store: store, now: now, calendar: calendar)
        }
        #expect(store.load() == original)
    }

    @Test func snoozeHonoursEveryOptionAndMaxSnoozes() throws {
        for option in SnoozeOption.allCases {
            let task = NagTask(
                title: option.label,
                startAt: now,
                style: NagStyle(maxSnoozes: 1),
                now: now
            )
            let store = store(containing: NagState(tasks: [task]))

            let snoozed = try NagActions.snooze(
                taskID: task.id,
                minutes: option.minutes,
                store: store,
                now: now,
                calendar: calendar
            )
            #expect(snoozed.snoozedUntil == now.addingTimeInterval(TimeInterval(option.minutes * 60)))
            #expect(snoozed.snoozeCount == 1)

            let bytesBeforeFailure = try stateData(in: store)
            #expect(throws: NagActions.Failure.cannotSnooze) {
                try NagActions.snooze(
                    taskID: task.id,
                    minutes: option.minutes,
                    store: store,
                    now: now,
                    calendar: calendar
                )
            }
            #expect(try stateData(in: store) == bytesBeforeFailure)
        }
    }

    @Test func snoozeWithNilMinutesUsesTheNagsOwnLength() throws {
        let task = NagTask(title: "Pause", startAt: now, style: NagStyle(snoozeMinutes: 42), now: now)
        let store = store(containing: NagState(tasks: [task]))

        let snoozed = try NagActions.snooze(taskID: task.id, store: store, now: now, calendar: calendar)

        #expect(snoozed.snoozedUntil == now.addingTimeInterval(42 * 60))
    }

    @Test func startBeginsAnOutstandingNagAndRefusesWhenRepeated() throws {
        let task = NagTask(title: "Focus", startAt: now, now: now)
        let store = store(containing: NagState(tasks: [task]))

        let started = try NagActions.start(taskID: task.id, store: store, now: now, calendar: calendar)
        #expect(throws: NagActions.Failure.cannotStart) {
            try NagActions.start(
                taskID: task.id,
                store: store,
                now: now.addingTimeInterval(60),
                calendar: calendar
            )
        }

        #expect(started.startedAt == now)
        #expect(store.load().task(task.id) == started)
    }

    @Test func startRefusesNagsThatAreNotOutstanding() throws {
        var finished = NagTask(title: "Finished", startAt: now, now: now)
        finished.complete(at: now, calendar: calendar)
        let future = NagTask(title: "Later", startAt: now.addingTimeInterval(3_600), now: now)
        let original = NagState(tasks: [finished, future])
        let store = store(containing: original)

        for task in original.tasks {
            #expect(throws: NagActions.Failure.cannotStart) {
                try NagActions.start(taskID: task.id, store: store, now: now, calendar: calendar)
            }
        }
        #expect(store.load() == original)
    }

    @Test func lockNowOnAnUnlockedProfileRelocksAndNeverExtendsTheUnlock() throws {
        var profile = LockProfile(name: "Work")
        let oldSession = LockSession(startedAt: now.addingTimeInterval(-600), trigger: .schedule)
        profile.status = .unlocked(oldSession, until: now.addingTimeInterval(3600))
        let store = store(containing: NagState(profiles: [profile]))

        let result = try NagActions.lockNow(profileID: profile.id, store: store, now: now, calendar: calendar)

        guard case .locked(let session) = result.status else {
            Issue.record("lockNow must replace a temporary unlock with a locked status")
            return
        }
        #expect(session.startedAt == now)
        #expect(session.trigger == .manual)
        #expect(result.unlockedUntil == nil)
        #expect(store.load().profile(profile.id) == result)
    }

    @Test func lockNowNeverDecreasesEngagement() throws {
        let existingSession = LockSession(startedAt: now.addingTimeInterval(-300), trigger: .nags)
        let statuses: [LockStatus] = [
            .off,
            .locked(existingSession),
            .unlocked(existingSession, until: now.addingTimeInterval(900)),
        ]

        for status in statuses {
            var profile = LockProfile(name: "Invariant")
            profile.status = status
            let store = store(containing: NagState(profiles: [profile]))

            let result = try NagActions.lockNow(profileID: profile.id, store: store, now: now, calendar: calendar)

            #expect(result.isEngaged)
            #expect(result.isLocked)
            if case .locked = status {
                #expect(result.status == status)
            }
        }
    }

    @Test func unlockStepsMatchesTheEvaluatorAndLeavesTheStoreUnchanged() throws {
        let task = NagTask(title: "Required nag", startAt: now, now: now)
        var profile = LockProfile(
            name: "Focus",
            requirements: [
                UnlockRequirement(kind: .completeTasks([task.id])),
                UnlockRequirement(kind: .walk(steps: 1_000)),
            ]
        )
        profile.status = .locked(LockSession(startedAt: now.addingTimeInterval(-600)))
        let original = NagState(tasks: [task], profiles: [profile])
        let store = store(containing: original)
        let bytesBefore = try stateData(in: store)
        let expected = UnlockEvaluator.evaluate(
            profile,
            state: original,
            steps: 250,
            now: now,
            calendar: calendar
        )

        let actual = try NagActions.unlockSteps(
            profileID: profile.id,
            steps: 250,
            store: store,
            now: now,
            calendar: calendar
        )

        #expect(actual == expected)
        #expect(store.load() == original)
        #expect(store.load().profile(profile.id)?.status == profile.status)
        #expect(try stateData(in: store) == bytesBefore)
    }

    @Test func missingIDsThrowWithoutMutatingTheStore() throws {
        let store = store(containing: NagState())
        let stateBefore = store.load()
        let missing = UUID()

        #expect(throws: NagActions.Failure.noSuchNag) {
            try NagActions.complete(taskID: missing, store: store, now: now, calendar: calendar)
        }
        #expect(throws: NagActions.Failure.noSuchNag) {
            try NagActions.snooze(taskID: missing, store: store, now: now, calendar: calendar)
        }
        #expect(throws: NagActions.Failure.noSuchNag) {
            try NagActions.start(taskID: missing, store: store, now: now, calendar: calendar)
        }
        #expect(throws: NagActions.Failure.noSuchLock) {
            try NagActions.lockNow(profileID: missing, store: store, now: now, calendar: calendar)
        }
        #expect(throws: NagActions.Failure.noSuchLock) {
            try NagActions.unlockSteps(profileID: missing, store: store, now: now, calendar: calendar)
        }
        #expect(store.load() == stateBefore)
    }

    @Test func parsesEveryRouteShape() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!
        let cases: [(String, NagRoute)] = [
            ("nag://add?title=One", .add(NagRequest(title: "One"))),
            ("nag://new?title=Two", .add(NagRequest(title: "Two"))),
            ("nag://new-nag", .newNag),
            ("nag://newnag", .newNag),
            ("NAG://Nags", .nags),
            ("nag://nag?id=\(id.uuidString)", .nag(id)),
            ("nag://scan?id=\(id.uuidString)", .scan(taskID: id)),
            ("nag://unlock?id=\(id.uuidString)", .unlock(profileID: id)),
        ]

        for (urlString, expected) in cases {
            let route = try NagRoute(url: URL(string: urlString)!, now: now, calendar: calendar)
            #expect(route == expected, "Failed to parse \(urlString)")
        }
    }

    @Test func unknownHostsStillThrowUnsupportedURL() {
        for urlString in ["nag://wat", "nag://", "https://example.com/nags"] {
            #expect(throws: NagRequestError.unsupportedURL) {
                try NagRoute(url: URL(string: urlString)!, now: now, calendar: calendar)
            }
        }
    }

    @Test func missingOrMalformedIDThrowsInvalidValue() {
        #expect(throws: NagRequestError.invalidValue(parameter: "id", value: "")) {
            try NagRoute(url: URL(string: "nag://scan")!, now: now, calendar: calendar)
        }
        #expect(throws: NagRequestError.invalidValue(parameter: "id", value: "banana")) {
            try NagRoute(url: URL(string: "nag://scan?id=banana")!, now: now, calendar: calendar)
        }
    }

    @Test func routesRoundTripThroughURL() throws {
        let id = UUID()
        let routes: [NagRoute] = [
            .newNag,
            .nags,
            .nag(id),
            .scan(taskID: id),
            .unlock(profileID: id),
        ]

        for route in routes {
            #expect(try NagRoute(url: route.url, now: now, calendar: calendar) == route)
        }
    }

    @Test func addRouteDelegatesToTheExistingNagRequestParser() throws {
        let url = URL(
            string: "nag://add?title=Stretch&at=2026-10-29T08:30&repeat=every_days&every_days=3"
                + "&source=Muse&id=card-42&link=https%3A%2F%2Fmuse.app%2Fcard"
        )!
        let existingRequest = try NagRequest(url: url, now: now, calendar: calendar)

        let route = try NagRoute(url: url, now: now, calendar: calendar)

        #expect(route == .add(existingRequest))
    }

    @Test func nagAddStillParsesDirectlyThroughNagRequestExactlyAsBefore() throws {
        let url = URL(
            string: "nag://add?title=Buy+milk+%2B+eggs&notes=Today&at=17:30&repeat=weekdays&every=5"
                + "&escalation=relentless&snooze=15&snoozes=unlimited&focus=no"
                + "&source=Calendar&id=event-7&link=https%3A%2F%2Fexample.com%2Fevent"
        )!

        let request = try NagRequest(url: url, now: now, calendar: calendar)

        #expect(request.title == "Buy milk + eggs")
        #expect(request.notes == "Today")
        #expect(request.startAt == Fixture.date(28, 17, 30))
        #expect(request.repeatRule == .weekdays)
        #expect(request.intervalMinutes == 5)
        #expect(request.escalation == .relentless)
        #expect(request.snoozeMinutes == 15)
        #expect(request.snoozeLimit == .unlimited)
        #expect(request.breakThroughFocus == false)
        #expect(request.source == "Calendar")
        #expect(request.externalID == "event-7")
        #expect(request.link == URL(string: "https://example.com/event"))
    }

    @Test func everyRepeatRuleExceptCustomIsExpressibleInShortcuts() {
        // Keep this set synchronized with NagRepeatOption in the app target.
        #expect(Set(RepeatRule.allCases) == [.never, .daily, .weekdays, .weekly, .custom, .everyNDays, .monthly])
        #expect(Set(RepeatRule.allCases.filter { $0 != .custom }) == [.never, .daily, .weekdays, .weekly, .everyNDays, .monthly])
    }

    @Test func presetIDsAreStableAndMatchTheShortcutsEnumRawValues() {
        // These are the raw values of NagPresetOption in CreateNagIntent.swift.
        #expect(NagPreset.all.map(\.id) == ["medication", "chore", "appointment", "someday"])
    }

    @Test func applyingAPresetWithNoKeysLeavesTapDoneProof() {
        var task = NagTask(title: "Medication", proof: .scanKey(UUID()), now: now)

        NagPreset.medication.apply(to: &task, keys: [], now: now, calendar: calendar)

        #expect(task.proof == .none)
    }

    @Test func everyNDaysAndMonthlyRequestsValidateAndRejectInvalidRanges() throws {
        let state = NagState()
        let every = NagRequest(title: "Water plants", repeatRule: .everyNDays, repeatEvery: 3)
        let monthly = NagRequest(title: "Pay bill", repeatRule: .monthly, monthDay: 31)

        #expect(try state.draft(for: every, now: now, calendar: calendar).task.repeatEvery == 3)
        #expect(try state.draft(for: monthly, now: now, calendar: calendar).task.monthDay == 31)
        #expect(throws: NagRequestError.invalidValue(parameter: "every days", value: "0")) {
            try state.draft(
                for: NagRequest(title: "Invalid", repeatRule: .everyNDays, repeatEvery: 0),
                now: now,
                calendar: calendar
            )
        }
        #expect(throws: NagRequestError.invalidValue(parameter: "month day", value: "0")) {
            try state.draft(
                for: NagRequest(title: "Invalid", repeatRule: .monthly, monthDay: 0),
                now: now,
                calendar: calendar
            )
        }
    }
}
