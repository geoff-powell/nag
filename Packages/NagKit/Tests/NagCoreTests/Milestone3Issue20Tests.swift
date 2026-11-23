import Foundation
import Testing
@testable import NagCore

@Suite struct Milestone3Issue20Tests {
    private let calendar = Fixture.calendar
    private let now = Fixture.date(28, 10)

    private func store(containing state: NagState = NagState()) -> SharedStore {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let store = SharedStore(directory: directory)
        store.update { $0 = state }
        return store
    }

    @Test func focusFilterTurnsOnChosenLocksAndReleasesThemWhenFocusEnds() {
        let social = LockProfile(name: "Social")
        let games = LockProfile(name: "Games")
        var state = NagState(profiles: [social, games])

        state.applyFocusFilter(lockIDs: [social.id], now: now, calendar: calendar)

        #expect(state.profile(social.id)?.isLocked == true)
        #expect(state.profile(social.id)?.session?.trigger == .focus)
        #expect(state.profile(games.id)?.status == .off)

        state.applyFocusFilter(now: now.addingTimeInterval(3600), calendar: calendar)

        #expect(state.profile(social.id)?.status == .off)
        #expect(state.profile(games.id)?.status == .off)
        #expect(!state.settings.focusFilter.isActive)
    }

    @Test func focusFilterNeverSwitchesOffLocksTurnedOnBySomethingElse() {
        var manual = LockProfile(name: "Manual")
        manual.lock(at: Fixture.date(28, 8), trigger: .manual)

        let scheduled = LockProfile(
            name: "Scheduled",
            schedule: LockSchedule(startMinute: 9 * 60, endMinute: 17 * 60, weekdays: Set(1...7))
        )

        let dueTask = NagTask(title: "Dishes", startAt: Fixture.date(28, 8), now: Fixture.date(28, 7))
        let nagDriven = LockProfile(
            name: "While due",
            requirements: [UnlockRequirement(kind: .clearDueNags)],
            lockWhileNagsDue: true
        )

        var unlockedManual = LockProfile(
            name: "Temporarily open",
            requirements: [UnlockRequirement(kind: .wait(minutes: 5))],
            unlockMinutes: 30
        )
        unlockedManual.status = .unlocked(
            LockSession(startedAt: Fixture.date(28, 9, 45), trigger: .manual),
            until: Fixture.date(28, 10, 15)
        )

        var state = NagState(
            tasks: [dueTask],
            profiles: [manual, scheduled, nagDriven, unlockedManual]
        )
        LockMaintenance.run(&state, now: Fixture.date(28, 9, 30), calendar: calendar)
        #expect(state.profile(scheduled.id)?.session?.trigger == .schedule)
        #expect(state.profile(nagDriven.id)?.session?.trigger == .nags)

        let allIDs = Set(state.profiles.map(\.id))
        state.applyFocusFilter(lockIDs: allIDs, now: now, calendar: calendar)

        // Focus must not steal ownership of locks that were already engaged.
        #expect(state.profile(manual.id)?.session?.trigger == .manual)
        #expect(state.profile(scheduled.id)?.session?.trigger == .schedule)
        #expect(state.profile(nagDriven.id)?.session?.trigger == .nags)
        #expect(state.profile(unlockedManual.id)?.session?.trigger == .manual)
        #expect(state.profile(unlockedManual.id)?.unlockedUntil == Fixture.date(28, 10, 15))

        // Ending Focus leaves every non-Focus lock engaged.
        state.applyFocusFilter(now: Fixture.date(28, 10, 5), calendar: calendar)

        #expect(state.profile(manual.id)?.isLocked == true)
        #expect(state.profile(scheduled.id)?.isLocked == true)
        #expect(state.profile(nagDriven.id)?.isLocked == true)
        #expect(state.profile(unlockedManual.id)?.isEngaged == true)
    }

    @Test func unlockEarnedMidFocusSticksUntilNextFocusActivation() {
        let social = LockProfile(name: "Social")
        var state = NagState(profiles: [social])

        state.applyFocusFilter(lockIDs: [social.id], minimumUrgency: .all, now: now, calendar: calendar)
        #expect(state.profiles[0].isLocked)

        // Emergency unlock mid-Focus stays unlocked across maintenance and Focus filter edits.
        state.profiles[0].emergencyUnlock(at: Fixture.date(28, 10, 15))
        LockMaintenance.run(&state, now: Fixture.date(28, 10, 30), calendar: calendar)
        #expect(state.profiles[0].status == .off)

        state.applyFocusFilter(lockIDs: [social.id], minimumUrgency: .gentle, now: Fixture.date(28, 10, 45), calendar: calendar)
        #expect(state.profiles[0].status == .off)

        // Ending Focus and turning it back on starts a fresh Focus lock session.
        state.applyFocusFilter(now: Fixture.date(28, 11), calendar: calendar)
        state.applyFocusFilter(lockIDs: [social.id], now: Fixture.date(28, 12), calendar: calendar)
        #expect(state.profiles[0].isLocked)
        #expect(state.profiles[0].session?.trigger == .focus)
    }

    @Test func timedUnlockUnderFocusRelocksWhileFocusStaysOnAndReleasesWhenFocusEnds() {
        let phrase = UnlockRequirement(kind: .typePhrase("Stay intentional"))
        let social = LockProfile(name: "Social", requirements: [phrase], unlockMinutes: 30)
        var state = NagState(profiles: [social])

        state.applyFocusFilter(lockIDs: [social.id], now: Fixture.date(28, 9), calendar: calendar)
        state.profiles[0].recordProof(phrase.id)
        LockMaintenance.run(&state, now: Fixture.date(28, 9, 5), calendar: calendar)
        #expect(state.profiles[0].unlockedUntil == Fixture.date(28, 9, 35))

        // Still in Focus when the temporary unlock expires: relocks under Focus.
        LockMaintenance.run(&state, now: Fixture.date(28, 9, 36), calendar: calendar)
        #expect(state.profiles[0].isLocked)
        #expect(state.profiles[0].session?.trigger == .focus)

        // Unlock again, then end Focus before the window expires: switches completely off.
        state.profiles[0].recordProof(phrase.id)
        LockMaintenance.run(&state, now: Fixture.date(28, 9, 40), calendar: calendar)
        #expect(state.profiles[0].unlockedUntil == Fixture.date(28, 10, 10))

        state.applyFocusFilter(now: Fixture.date(28, 9, 50), calendar: calendar)
        #expect(state.profiles[0].status == .off)
    }

    @Test func overlappingFocusAndScheduleHandOverCleanlyInEitherOrder() {
        let workday = LockSchedule(startMinute: 9 * 60, endMinute: 17 * 60, weekdays: Set(1...7))
        let profile = LockProfile(name: "Work", schedule: workday)

        // Focus starts at 8:30, schedule starts at 9:00, Focus ends at 12:00 -> stays locked until 17:00.
        var focusFirst = NagState(profiles: [profile])
        focusFirst.applyFocusFilter(lockIDs: [profile.id], now: Fixture.date(28, 8, 30), calendar: calendar)
        #expect(focusFirst.profiles[0].session?.trigger == .focus)

        LockMaintenance.run(&focusFirst, now: Fixture.date(28, 9, 5), calendar: calendar)
        focusFirst.applyFocusFilter(now: Fixture.date(28, 12), calendar: calendar)
        #expect(focusFirst.profiles[0].isLocked)
        #expect(focusFirst.profiles[0].session?.trigger == .schedule)

        LockMaintenance.run(&focusFirst, now: Fixture.date(28, 17, 1), calendar: calendar)
        #expect(focusFirst.profiles[0].status == .off)

        // Schedule starts at 9:00, Focus starts at 16:00, schedule ends at 17:00 -> stays locked until Focus ends.
        var scheduleFirst = NagState(profiles: [profile])
        LockMaintenance.run(&scheduleFirst, now: Fixture.date(28, 9, 5), calendar: calendar)
        #expect(scheduleFirst.profiles[0].session?.trigger == .schedule)

        scheduleFirst.applyFocusFilter(lockIDs: [profile.id], now: Fixture.date(28, 16), calendar: calendar)
        LockMaintenance.run(&scheduleFirst, now: Fixture.date(28, 17, 1), calendar: calendar)
        #expect(scheduleFirst.profiles[0].isLocked)
        #expect(scheduleFirst.profiles[0].session?.trigger == .focus)

        scheduleFirst.applyFocusFilter(now: Fixture.date(28, 18), calendar: calendar)
        #expect(scheduleFirst.profiles[0].status == .off)
    }

    @Test func switchingBetweenFocusFiltersAddsAndRemovesLocksIndependently() {
        let social = LockProfile(name: "Social")
        let mail = LockProfile(name: "Mail")
        let games = LockProfile(name: "Games")
        var state = NagState(profiles: [social, mail, games])

        state.applyFocusFilter(lockIDs: [social.id], now: Fixture.date(28, 9), calendar: calendar)
        #expect(state.profile(social.id)?.isLocked == true)

        state.applyFocusFilter(lockIDs: [social.id, mail.id], now: Fixture.date(28, 10), calendar: calendar)
        #expect(state.settings.focusFilter.lockStarts[social.id] == Fixture.date(28, 9))
        #expect(state.settings.focusFilter.lockStarts[mail.id] == Fixture.date(28, 10))
        #expect(state.profile(mail.id)?.isLocked == true)

        state.applyFocusFilter(lockIDs: [games.id], now: Fixture.date(28, 11), calendar: calendar)
        #expect(state.profile(social.id)?.status == .off)
        #expect(state.profile(mail.id)?.status == .off)
        #expect(state.profile(games.id)?.isLocked == true)
    }

    @Test func minimumUrgencyQuietsLowerUrgencyAndFocusOptOutNags() {
        let someday = NagTask(
            title: "Clean drawer",
            startAt: now.addingTimeInterval(-600),
            style: NagStyle(intervalMinutes: 60, escalation: .steady, breakThroughFocus: true),
            now: now
        )
        let chore = NagTask(
            title: "Unload dishwasher",
            startAt: now.addingTimeInterval(-300),
            style: NagStyle(intervalMinutes: 15, escalation: .gentle, breakThroughFocus: true),
            now: now
        )
        let meds = NagTask(
            title: "Take medication",
            startAt: now.addingTimeInterval(-120),
            style: NagStyle(intervalMinutes: 5, escalation: .relentless, breakThroughFocus: true),
            now: now
        )
        let optedOut = NagTask(
            title: "Quiet relentless",
            startAt: now.addingTimeInterval(-60),
            style: NagStyle(intervalMinutes: 5, escalation: .relentless, breakThroughFocus: false),
            now: now
        )
        let upcomingChore = NagTask(
            title: "Later chore",
            startAt: now.addingTimeInterval(1800),
            style: NagStyle(intervalMinutes: 15, escalation: .gentle, breakThroughFocus: true),
            now: now
        )
        let tasks = [someday, chore, meds, optedOut, upcomingChore]
        let planner = NagPlanner(calendar: calendar)

        let allPlan = planner.plan(
            tasks: tasks,
            quietHours: QuietHours(),
            focusFilter: FocusFilter(minimumUrgency: .all),
            now: now
        )
        #expect(Set(allPlan.notifications.map(\.taskID)) == Set(tasks.map(\.id)))
        #expect(allPlan.outstandingCount == 4)

        let gentlePlan = planner.plan(
            tasks: tasks,
            quietHours: QuietHours(),
            focusFilter: FocusFilter(minimumUrgency: .gentle),
            now: now
        )
        #expect(Set(gentlePlan.notifications.map(\.taskID)) == [chore.id, meds.id, upcomingChore.id])
        #expect(gentlePlan.outstandingCount == 4)

        let relentlessFilter = FocusFilter(minimumUrgency: .relentless)
        let relentlessPlan = planner.plan(
            tasks: tasks,
            quietHours: QuietHours(),
            focusFilter: relentlessFilter,
            now: now
        )
        #expect(Set(relentlessPlan.notifications.map(\.taskID)) == [meds.id])
        #expect(relentlessPlan.outstandingCount == 4)

        // Live Activities also skip quieted nags so an urgent nag isn't hidden behind an older steady one.
        let state = NagState(tasks: tasks, settings: AppSettings(focusFilter: relentlessFilter))
        #expect(NagActivityContent.make(task: someday, state: state, tone: .standard, now: now, calendar: calendar) == nil)
        #expect(NagActivityContent.make(task: chore, state: state, tone: .standard, now: now, calendar: calendar) == nil)
        #expect(NagActivityContent.make(task: meds, state: state, tone: .standard, now: now, calendar: calendar)?.taskID == meds.id)
    }

    @Test func focusQuietHoursSilencesAllNagsWithoutChangingSavedQuietHoursOrSyncStamp() {
        let meds = NagTask(
            title: "Take medication",
            startAt: now.addingTimeInterval(-120),
            style: NagStyle(intervalMinutes: 5, escalation: .relentless, breakThroughFocus: true),
            now: now
        )
        let savedQuietHours = QuietHours(enabled: false, startMinute: 22 * 60, endMinute: 8 * 60)
        var state = NagState(tasks: [meds], settings: AppSettings(quietHours: savedQuietHours))
        let syncedBefore = state.settings.syncedQuietHours

        // 10:00 is outside 22:00–08:00, and saved quiet hours are off, yet Focus quiet hours silence nagging.
        state.applyFocusFilter(quietHours: true, now: now, calendar: calendar)
        #expect(state.settings.isQuietHoursActive(at: now, calendar: calendar))
        #expect(state.settings.quietHours == savedQuietHours)
        #expect(state.settings.syncedQuietHours == syncedBefore)

        let planner = NagPlanner(calendar: calendar)
        let quietPlan = planner.plan(
            tasks: state.tasks,
            quietHours: state.settings.quietHours,
            focusFilter: state.settings.focusFilter,
            now: now
        )
        #expect(quietPlan.notifications.isEmpty)
        #expect(quietPlan.nextWake == nil)
        #expect(quietPlan.outstandingCount == 1)

        // Ending Focus restores nagging immediately.
        state.applyFocusFilter(now: now.addingTimeInterval(1800), calendar: calendar)
        #expect(!state.settings.isQuietHoursActive(at: now.addingTimeInterval(1800), calendar: calendar))
        let resumedPlan = planner.plan(
            tasks: state.tasks,
            quietHours: state.settings.quietHours,
            focusFilter: state.settings.focusFilter,
            now: now.addingTimeInterval(1800)
        )
        #expect(resumedPlan.notifications.map(\.taskID) == [meds.id])
    }

    @Test func notificationFilterPredicateMatchesPlannedFilterCriteria() {
        let steady = FocusUrgency.filterCriteria(for: NagStyle(escalation: .steady, breakThroughFocus: true))
        let gentle = FocusUrgency.filterCriteria(for: NagStyle(escalation: .gentle, breakThroughFocus: true))
        let relentless = FocusUrgency.filterCriteria(for: NagStyle(escalation: .relentless, breakThroughFocus: true))
        let focusOff = FocusUrgency.filterCriteria(for: NagStyle(escalation: .relentless, breakThroughFocus: false))
        let system = FocusUrgency.systemFilterCriteria

        #expect(FocusFilter(minimumUrgency: .all).notificationFilterPredicate == nil)

        let gentlePredicate = FocusFilter(minimumUrgency: .gentle).notificationFilterPredicate!
        #expect(!gentlePredicate.evaluate(with: steady))
        #expect(gentlePredicate.evaluate(with: gentle))
        #expect(gentlePredicate.evaluate(with: relentless))
        #expect(!gentlePredicate.evaluate(with: focusOff))
        #expect(gentlePredicate.evaluate(with: system))

        let relentlessPredicate = FocusFilter(minimumUrgency: .relentless).notificationFilterPredicate!
        #expect(!relentlessPredicate.evaluate(with: steady))
        #expect(!relentlessPredicate.evaluate(with: gentle))
        #expect(relentlessPredicate.evaluate(with: relentless))
        #expect(!relentlessPredicate.evaluate(with: focusOff))
        #expect(relentlessPredicate.evaluate(with: system))

        let quietPredicate = FocusFilter(minimumUrgency: .relentless, quietHours: true).notificationFilterPredicate!
        #expect(!quietPredicate.evaluate(with: steady))
        #expect(!quietPredicate.evaluate(with: gentle))
        #expect(!quietPredicate.evaluate(with: relentless))
        #expect(!quietPredicate.evaluate(with: focusOff))
        #expect(quietPredicate.evaluate(with: system))
    }

    @Test func lockingByHandDuringFocusOutlastsTheFocus() {
        let social = LockProfile(name: "Social")
        var state = NagState(profiles: [social])
        state.applyFocusFilter(lockIDs: [social.id], now: now, calendar: calendar)

        state.profiles[0].lock(at: now.addingTimeInterval(60))
        #expect(state.profiles[0].session?.trigger == .manual)

        state.applyFocusFilter(now: now.addingTimeInterval(3600), calendar: calendar)
        #expect(state.profiles[0].isLocked)
    }

    @Test func expiredNagsUnlockHandsOverToAnActiveFocus() {
        let task = NagTask(title: "Dishes", startAt: Fixture.date(28, 9), now: Fixture.date(28, 8))
        let phrase = UnlockRequirement(kind: .typePhrase("Later"))
        var profile = LockProfile(name: "While due", requirements: [phrase], unlockMinutes: 30, lockWhileNagsDue: true)
        profile.status = .unlocked(
            LockSession(startedAt: Fixture.date(28, 9), trigger: .nags),
            until: Fixture.date(28, 10, 30)
        )
        var state = NagState(tasks: [task], profiles: [profile])
        state.applyFocusFilter(lockIDs: [profile.id], now: now, calendar: calendar)
        state.tasks[0].complete(at: Fixture.date(28, 10, 10), calendar: calendar)

        LockMaintenance.run(&state, now: Fixture.date(28, 10, 31), calendar: calendar)

        #expect(state.profiles[0].isLocked)
        #expect(state.profiles[0].session?.trigger == .focus)
    }

    @Test func deletedLocksAreDroppedFromTheFocusFilter() {
        let social = LockProfile(name: "Social")
        var state = NagState(profiles: [social])
        state.applyFocusFilter(lockIDs: [social.id], now: now, calendar: calendar)
        state.profiles.removeAll()

        LockMaintenance.run(&state, now: now.addingTimeInterval(60), calendar: calendar)

        #expect(state.settings.focusFilter.lockStarts.isEmpty)
        #expect(!state.settings.focusFilter.isActive)
    }

    @Test func codableBackwardsCompatibilityStoreRoundTripAndSummaryFormatting() throws {
        let legacySettingsJSON = Data(#"{"quietHours":{"enabled":false,"startMinute":1320,"endMinute":480}}"#.utf8)
        let decodedSettings = try JSONDecoder().decode(AppSettings.self, from: legacySettingsJSON)
        #expect(decodedSettings.focusFilter == FocusFilter())

        let futureUrgencyJSON = Data(#""super-alarm""#.utf8)
        #expect(try JSONDecoder().decode(FocusUrgency.self, from: futureUrgencyJSON) == .all)

        let futureTriggerJSON = Data(#""geofence""#.utf8)
        #expect(try JSONDecoder().decode(LockTrigger.self, from: futureTriggerJSON) == .manual)

        let profile = LockProfile(name: "Social")
        let store = store(containing: NagState(profiles: [profile]))
        store.update { state in
            state.applyFocusFilter(
                lockIDs: [profile.id],
                minimumUrgency: .relentless,
                quietHours: false,
                now: now,
                calendar: calendar
            )
        }
        let loaded = store.load()
        #expect(loaded.profile(profile.id)?.session?.trigger == .focus)
        #expect(loaded.settings.focusFilter.minimumUrgency == .relentless)
        #expect(loaded.settings.focusFilter.lockStarts == [profile.id: now])

        // Ensure lockStarts encodes as a JSON object keyed by UUID strings, not an alternating array.
        let rawObject = try JSONSerialization.jsonObject(
            with: Data(contentsOf: store.directory.appending(path: "state.json"))
        ) as? [String: Any]
        let settingsDict = rawObject?["settings"] as? [String: Any]
        let filterDict = settingsDict?["focusFilter"] as? [String: Any]
        let lockStartsDict = filterDict?["lockStarts"] as? [String: Any]
        #expect(lockStartsDict?[profile.id.uuidString] != nil)

        #expect(
            FocusFilterSummary.make(lockNames: ["Social"], minimumUrgency: .gentle, quietHours: false)
                == FocusFilterSummary(title: "Lock Social", subtitle: "Gentle and relentless nags")
        )
        #expect(
            FocusFilterSummary.make(lockNames: [], minimumUrgency: .relentless, quietHours: false)
                == FocusFilterSummary(title: "Relentless nags only", subtitle: "No locks")
        )
        #expect(
            FocusFilterSummary.make(lockNames: [], minimumUrgency: .all, quietHours: true)
                == FocusFilterSummary(title: "Quiet hours on", subtitle: "All nags paused")
        )
        #expect(
            FocusFilterSummary.make(lockNames: [], minimumUrgency: .all, quietHours: false)
                == FocusFilterSummary(title: "No changes", subtitle: "All nags, no locks")
        )
    }
}
