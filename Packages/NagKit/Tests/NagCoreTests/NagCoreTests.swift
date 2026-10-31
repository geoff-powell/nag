import Foundation
import Testing
@testable import NagCore

/// Fixed calendar and dates so tests don't depend on the machine's time zone.
enum Fixture {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// 2026-10-28 is a Wednesday.
    static func date(_ day: Int = 28, _ hour: Int, _ minute: Int = 0, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }
}

struct TaskRuleTests {
    let calendar = Fixture.calendar

    @Test func dailyOccurrenceRollsToTomorrow() {
        let anchor = Fixture.date(28, 8)
        #expect(RepeatRule.daily.occurrence(after: Fixture.date(28, 9), anchor: anchor, calendar: calendar) == Fixture.date(29, 8))
        #expect(RepeatRule.daily.occurrence(after: Fixture.date(28, 7), anchor: anchor, calendar: calendar) == Fixture.date(28, 8))
    }

    @Test func weekdaysSkipTheWeekend() {
        // Friday 30th 9:00 -> Monday 2 Nov 8:00.
        let next = RepeatRule.weekdays.occurrence(after: Fixture.date(30, 9), anchor: Fixture.date(28, 8), calendar: calendar)
        #expect(next == Fixture.date(2, 8, month: 11))
    }

    @Test func weeklyKeepsTheAnchorWeekday() {
        let next = RepeatRule.weekly.occurrence(after: Fixture.date(28, 9), anchor: Fixture.date(28, 8), calendar: calendar)
        #expect(next == Fixture.date(4, 8, month: 11))
    }

    @Test func completingOneOffFinishesIt() {
        var task = NagTask(title: "Taxes", startAt: Fixture.date(28, 8), now: Fixture.date(28, 7))
        #expect(!task.isSatisfied(at: Fixture.date(28, 9), calendar: calendar))
        task.complete(at: Fixture.date(28, 9), calendar: calendar)
        #expect(task.isFinished)
        #expect(task.nagStart == nil)
        #expect(task.isSatisfied(at: Fixture.date(28, 9), calendar: calendar))
    }

    @Test func completingRepeatingEarlyCountsForToday() {
        var task = NagTask(title: "Meds", startAt: Fixture.date(28, 8), repeatRule: .daily, now: Fixture.date(27, 20))
        #expect(!task.isSatisfied(at: Fixture.date(28, 7), calendar: calendar))
        task.complete(at: Fixture.date(28, 7), calendar: calendar)
        #expect(task.startAt == Fixture.date(29, 8))
        #expect(task.isSatisfied(at: Fixture.date(28, 12), calendar: calendar))
        #expect(!task.canComplete(at: Fixture.date(28, 12), calendar: calendar))
        // Tomorrow it's owed again.
        #expect(!task.isSatisfied(at: Fixture.date(29, 7), calendar: calendar))
    }

    @Test func completingRepeatingLateSkipsMissedOccurrences() {
        var task = NagTask(title: "Meds", startAt: Fixture.date(25, 8), repeatRule: .daily, now: Fixture.date(24, 8))
        task.complete(at: Fixture.date(28, 9), calendar: calendar)
        #expect(task.startAt == Fixture.date(29, 8))
    }

    @Test func snoozesRunOut() {
        var task = NagTask(title: "Laundry", startAt: Fixture.date(28, 8), style: NagStyle(snoozeMinutes: 10, maxSnoozes: 2), now: Fixture.date(28, 8))
        let now = Fixture.date(28, 9)
        let first = task.snooze(at: now)
        #expect(first)
        #expect(task.nagStart == Fixture.date(28, 9, 10))
        #expect(task.isSnoozed(at: now))
        #expect(task.isOutstanding(at: now))
        let second = task.snooze(at: now)
        let third = task.snooze(at: now)
        #expect(second)
        #expect(!third)
        #expect(task.snoozesLeft == 0)
    }

    @Test func cantSnoozeSomethingNotStarted() {
        var task = NagTask(title: "Later", startAt: Fixture.date(28, 18), now: Fixture.date(28, 8))
        let snoozed = task.snooze(at: Fixture.date(28, 9))
        #expect(!snoozed)
    }

    @Test func duplicateKeepsSettingsButNotProgress() {
        var task = NagTask(
            title: "Meds",
            notes: "With food",
            startAt: Fixture.date(28, 8),
            repeatRule: .custom,
            times: [NagTime(minute: 8 * 60, weekdays: [2, 4, 6])],
            style: NagStyle(intervalMinutes: 5, escalation: .relentless),
            now: Fixture.date(27, 8)
        )
        _ = task.snooze(at: Fixture.date(28, 9))
        let copy = task.duplicate(now: Fixture.date(28, 10))
        #expect(copy.id != task.id)
        #expect(copy.title == "Meds copy")
        #expect(copy.notes == task.notes)
        #expect(copy.startAt == task.startAt)
        #expect(copy.repeatRule == .custom)
        #expect(copy.times.map(\.minute) == [8 * 60])
        #expect(copy.times.map(\.weekdays) == [[2, 4, 6]])
        #expect(copy.times[0].id != task.times[0].id)
        #expect(copy.style == task.style)
        #expect(copy.createdAt == Fixture.date(28, 10))
        #expect(copy.snoozeCount == 0)
        #expect(copy.snoozedUntil == nil)
        #expect(copy.lastCompletedAt == nil)
    }
}

struct CustomScheduleTests {
    let calendar = Fixture.calendar

    /// 9 AM Mon, Wed, Fri and 11 PM Tue, Thu.
    func meds(startAt: Date = Fixture.date(28, 9)) -> NagTask {
        NagTask(
            title: "Meds",
            startAt: startAt,
            repeatRule: .custom,
            times: [NagTime(minute: 9 * 60, weekdays: [2, 4, 6]), NagTime(minute: 23 * 60, weekdays: [3, 5])],
            now: Fixture.date(27, 20)
        )
    }

    @Test func nextOccurrenceIsTheEarliestTime() {
        let task = meds()
        // Wed 28.
        #expect(task.occurrence(after: Fixture.date(28, 8), calendar: calendar) == Fixture.date(28, 9))
        #expect(task.occurrence(after: Fixture.date(28, 9), calendar: calendar) == Fixture.date(29, 23))
        // Thu 29 -> Fri 30.
        #expect(task.occurrence(after: Fixture.date(29, 23), calendar: calendar) == Fixture.date(30, 9))
        // Fri 30 -> skips the weekend -> Mon 2 Nov.
        #expect(task.occurrence(after: Fixture.date(30, 9), calendar: calendar) == Fixture.date(2, 9, month: 11))
    }

    @Test func twiceADayOwesBothBeforeTheDayIsSatisfied() {
        var task = NagTask(
            title: "Stretch",
            startAt: Fixture.date(28, 9),
            repeatRule: .custom,
            times: [NagTime(minute: 9 * 60), NagTime(minute: 21 * 60)],
            now: Fixture.date(27, 20)
        )
        task.complete(at: Fixture.date(28, 9, 30), calendar: calendar)
        #expect(task.startAt == Fixture.date(28, 21))
        #expect(!task.isSatisfied(at: Fixture.date(28, 12), calendar: calendar))
        task.complete(at: Fixture.date(28, 21, 10), calendar: calendar)
        #expect(task.startAt == Fixture.date(29, 9))
        #expect(task.isSatisfied(at: Fixture.date(28, 22), calendar: calendar))
    }

    @Test func completingLateSkipsMissedTimes() {
        var task = meds(startAt: Fixture.date(28, 9))
        // Done Friday at noon: Wed 9 AM, Thu 11 PM and Fri 9 AM are all behind us.
        task.complete(at: Fixture.date(30, 12), calendar: calendar)
        #expect(task.startAt == Fixture.date(2, 9, month: 11))
    }

    @Test func savingANewOrChangedScheduleMovesStartToTheNextTime() {
        var task = meds(startAt: Fixture.date(1, 0))
        task.alignStartToSchedule(previous: nil, now: Fixture.date(28, 10), calendar: calendar)
        #expect(task.startAt == Fixture.date(29, 23))

        // Unchanged times leave an overdue occurrence alone.
        let saved = task
        task.alignStartToSchedule(previous: saved, now: Fixture.date(30, 8), calendar: calendar)
        #expect(task.startAt == Fixture.date(29, 23))

        task.times.removeLast()
        task.alignStartToSchedule(previous: saved, now: Fixture.date(30, 8), calendar: calendar)
        #expect(task.startAt == Fixture.date(30, 9))
    }

    @Test func scheduleNeedsATimeAndADay() {
        var task = meds()
        #expect(task.hasValidSchedule)
        task.times[0].weekdays = []
        #expect(!task.hasValidSchedule)
        task.times = []
        #expect(!task.hasValidSchedule)
        task.repeatRule = .daily
        #expect(task.hasValidSchedule)
    }

    @Test func nagsSavedBeforeCustomTimesStillDecode() throws {
        let task = NagTask(title: "Old", startAt: Fixture.date(28, 9), repeatRule: .daily, now: Fixture.date(27, 9))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as! [String: Any]
        json.removeValue(forKey: "times")
        let decoded = try JSONDecoder().decode(NagTask.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == task)
    }
}

struct EscalationTests {
    @Test func steadyNeverChanges() {
        #expect(Escalation.steady.interval(base: 900, overdue: 10 * 3600) == 900)
        #expect(Escalation.steady.nextTightening(base: 900, overdue: 0) == nil)
    }

    @Test func gentleBottomsOutAtHalf() {
        #expect(Escalation.gentle.interval(base: 1200, overdue: 0) == 1200)
        #expect(Escalation.gentle.interval(base: 1200, overdue: 3600) == 900)
        #expect(Escalation.gentle.interval(base: 1200, overdue: 10 * 3600) == 600)
    }

    @Test func relentlessHalvesDownToAMinute() {
        #expect(Escalation.relentless.interval(base: 960, overdue: 0) == 960)
        #expect(Escalation.relentless.interval(base: 960, overdue: 1800) == 480)
        #expect(Escalation.relentless.interval(base: 960, overdue: 4 * 1800) == 60)
        #expect(Escalation.relentless.interval(base: 960, overdue: 100 * 1800) == 60)
        #expect(Escalation.relentless.nextTightening(base: 960, overdue: 100) == 1800)
        #expect(Escalation.relentless.nextTightening(base: 960, overdue: 10 * 1800) == nil)
    }

    @Test func neverUnderOneMinute() {
        #expect(Escalation.steady.interval(base: 10, overdue: 0) == 60)
    }
}

struct QuietHoursTests {
    let calendar = Fixture.calendar
    let overnight = QuietHours(enabled: true, startMinute: 22 * 60, endMinute: 8 * 60)

    @Test func overnightWindow() {
        #expect(overnight.contains(Fixture.date(28, 23), calendar: calendar))
        #expect(overnight.contains(Fixture.date(28, 3), calendar: calendar))
        #expect(!overnight.contains(Fixture.date(28, 8), calendar: calendar))
        #expect(!overnight.contains(Fixture.date(28, 21, 59), calendar: calendar))
    }

    @Test func nextAllowedJumpsToMorning() {
        #expect(overnight.nextAllowed(after: Fixture.date(28, 23), calendar: calendar) == Fixture.date(29, 8))
        #expect(overnight.nextAllowed(after: Fixture.date(28, 3), calendar: calendar) == Fixture.date(28, 8))
        #expect(overnight.nextAllowed(after: Fixture.date(28, 12), calendar: calendar) == Fixture.date(28, 12))
    }

    @Test func disabledIsNeverQuiet() {
        #expect(!QuietHours(enabled: false).contains(Fixture.date(28, 23), calendar: calendar))
    }
}

struct PlannerTests {
    let planner = NagPlanner(calendar: Fixture.calendar)

    @Test func dueNagGetsOneRepeatingNotification() {
        let task = NagTask(title: "Meds", startAt: Fixture.date(28, 8), style: NagStyle(intervalMinutes: 15, escalation: .steady), now: Fixture.date(28, 7))
        let plan = planner.plan(tasks: [task], quietHours: QuietHours(), now: Fixture.date(28, 8, 5))
        #expect(plan.notifications.count == 1)
        #expect(plan.notifications.first?.trigger == .every(seconds: 900))
        #expect(plan.outstandingCount == 1)
    }

    @Test func futureNagGetsOneOffsStartingOnTime() {
        let task = NagTask(title: "Call mum", startAt: Fixture.date(28, 18), style: NagStyle(intervalMinutes: 10, escalation: .steady), now: Fixture.date(28, 8))
        let plan = planner.plan(tasks: [task], quietHours: QuietHours(), now: Fixture.date(28, 9))
        guard case .at(let first) = plan.notifications.first?.trigger else {
            Issue.record("Expected a one-off notification")
            return
        }
        #expect(first == Fixture.date(28, 18))
        #expect(plan.notifications.count == 60)
        #expect(plan.nextWake == Fixture.date(28, 18))
        #expect(plan.outstandingCount == 0)
    }

    @Test func replanningKeepsIdentifiers() {
        let task = NagTask(title: "Call mum", startAt: Fixture.date(28, 18), now: Fixture.date(28, 8))
        let first = planner.plan(tasks: [task], quietHours: QuietHours(), now: Fixture.date(28, 9))
        let second = planner.plan(tasks: [task], quietHours: QuietHours(), now: Fixture.date(28, 9, 7))
        #expect(first.notifications.map(\.identifier) == second.notifications.map(\.identifier))
    }

    @Test func quietHoursHoldNagsUntilMorning() {
        let quiet = QuietHours(enabled: true, startMinute: 22 * 60, endMinute: 8 * 60)
        let task = NagTask(title: "Dishes", startAt: Fixture.date(28, 21, 30), style: NagStyle(intervalMinutes: 15, escalation: .steady), now: Fixture.date(28, 8))
        let plan = planner.plan(tasks: [task], quietHours: quiet, now: Fixture.date(28, 21))
        let dates = plan.notifications.compactMap { notification -> Date? in
            if case .at(let date) = notification.trigger { return date }
            return nil
        }
        #expect(dates.prefix(3) == [Fixture.date(28, 21, 30), Fixture.date(28, 21, 45), Fixture.date(29, 8)])
        #expect(!dates.contains { quiet.contains($0, calendar: Fixture.calendar) })
    }

    @Test func dueNagDuringQuietHoursWaitsForMorning() {
        let quiet = QuietHours(enabled: true, startMinute: 22 * 60, endMinute: 8 * 60)
        let task = NagTask(title: "Dishes", startAt: Fixture.date(28, 20), now: Fixture.date(28, 8))
        let plan = planner.plan(tasks: [task], quietHours: quiet, now: Fixture.date(28, 23))
        #expect(!plan.notifications.contains { if case .every = $0.trigger { true } else { false } })
        #expect(plan.nextWake == Fixture.date(29, 8))
    }

    @Test func budgetIsSharedEarliestFirst() {
        let soon = NagTask(title: "Soon", startAt: Fixture.date(28, 10), style: NagStyle(intervalMinutes: 5, escalation: .steady), now: Fixture.date(28, 8))
        let later = NagTask(title: "Later", startAt: Fixture.date(29, 10), style: NagStyle(intervalMinutes: 5, escalation: .steady), now: Fixture.date(28, 8))
        let plan = planner.plan(tasks: [soon, later], quietHours: QuietHours(), now: Fixture.date(28, 9))
        #expect(plan.notifications.count == 60)
        #expect(plan.notifications.allSatisfy { $0.taskID == soon.id })
    }

    @Test func snoozedNagRestartsAfterSnooze() {
        var task = NagTask(title: "Meds", startAt: Fixture.date(28, 8), now: Fixture.date(28, 7))
        task.snooze(at: Fixture.date(28, 8, 5))
        let plan = planner.plan(tasks: [task], quietHours: QuietHours(), now: Fixture.date(28, 8, 6))
        guard case .at(let first) = plan.notifications.first?.trigger else {
            Issue.record("Expected a one-off notification")
            return
        }
        #expect(first == Fixture.date(28, 8, 15))
        #expect(plan.outstandingCount == 1)
    }

    @Test func finishedNagsAreSilent() {
        var task = NagTask(title: "Done", startAt: Fixture.date(28, 8), now: Fixture.date(28, 7))
        task.complete(at: Fixture.date(28, 8, 1), calendar: Fixture.calendar)
        let plan = planner.plan(tasks: [task], quietHours: QuietHours(), now: Fixture.date(28, 9))
        #expect(plan.notifications.isEmpty)
        #expect(plan.outstandingCount == 0)
    }
}

struct LockTests {
    let calendar = Fixture.calendar

    @Test func scheduleWindowsIncludingOvernight() {
        let workday = LockSchedule(startMinute: 9 * 60, endMinute: 17 * 60, weekdays: [2, 3, 4, 5, 6])
        #expect(workday.windowStart(containing: Fixture.date(28, 10), calendar: calendar) == Fixture.date(28, 9))
        #expect(workday.windowStart(containing: Fixture.date(28, 17), calendar: calendar) == nil)
        // Saturday 31st.
        #expect(workday.windowStart(containing: Fixture.date(31, 10), calendar: calendar) == nil)

        let bedtime = LockSchedule(startMinute: 23 * 60, endMinute: 7 * 60, weekdays: Set(1...7))
        #expect(bedtime.windowStart(containing: Fixture.date(29, 2), calendar: calendar) == Fixture.date(28, 23))
        #expect(bedtime.durationMinutes == 8 * 60)
    }

    @Test func scheduleLocksOncePerWindow() {
        var state = NagState(profiles: [LockProfile(name: "Work", schedule: LockSchedule(startMinute: 9 * 60, endMinute: 17 * 60, weekdays: Set(1...7)))])
        LockMaintenance.run(&state, now: Fixture.date(28, 9, 1), calendar: calendar)
        #expect(state.profiles[0].session?.trigger == .schedule)

        // An emergency unlock mid-window sticks.
        state.profiles[0].emergencyUnlock(at: Fixture.date(28, 10))
        LockMaintenance.run(&state, now: Fixture.date(28, 11), calendar: calendar)
        #expect(state.profiles[0].status == .off)

        // The next day's window locks again, and the end of the window releases it.
        LockMaintenance.run(&state, now: Fixture.date(29, 9, 30), calendar: calendar)
        #expect(state.profiles[0].isLocked)
        LockMaintenance.run(&state, now: Fixture.date(29, 17, 1), calendar: calendar)
        #expect(state.profiles[0].status == .off)
    }

    @Test func manualLockOutlastsSchedule() {
        var state = NagState(profiles: [LockProfile(name: "Work", schedule: LockSchedule(startMinute: 9 * 60, endMinute: 17 * 60, weekdays: Set(1...7)))])
        state.profiles[0].lock(at: Fixture.date(28, 8))
        LockMaintenance.run(&state, now: Fixture.date(28, 18), calendar: calendar)
        #expect(state.profiles[0].isLocked)
    }

    @Test func nagOnlyLockAutoUnlocksAndSwitchesOff() {
        let task = NagTask(title: "Meds", startAt: Fixture.date(28, 8), now: Fixture.date(28, 7))
        var profile = LockProfile(name: "Morning", requirements: [UnlockRequirement(kind: .completeTasks([task.id]))], unlockMinutes: 30)
        profile.lock(at: Fixture.date(28, 7))
        var state = NagState(tasks: [task], profiles: [profile])

        #expect(LockMaintenance.run(&state, now: Fixture.date(28, 9), calendar: calendar).isEmpty)
        #expect(state.profiles[0].isLocked)

        state.tasks[0].complete(at: Fixture.date(28, 9, 5), calendar: calendar)
        let unlocked = LockMaintenance.run(&state, now: Fixture.date(28, 9, 5), calendar: calendar)
        #expect(unlocked.map(\.id) == [profile.id])
        #expect(state.profiles[0].status == .off)
    }

    @Test func timedUnlockComesBackAndNeedsRedoing() {
        let phrase = UnlockRequirement(kind: .typePhrase("I choose this"))
        var profile = LockProfile(name: "Social", requirements: [phrase], unlockMinutes: 30)
        profile.lock(at: Fixture.date(28, 9))
        profile.recordProof(phrase.id)
        var state = NagState(profiles: [profile])

        LockMaintenance.run(&state, now: Fixture.date(28, 9, 10), calendar: calendar)
        #expect(state.profiles[0].unlockedUntil == Fixture.date(28, 9, 40))
        #expect(!state.profiles[0].isShielding(at: Fixture.date(28, 9, 20)))

        LockMaintenance.run(&state, now: Fixture.date(28, 9, 41), calendar: calendar)
        #expect(state.profiles[0].isLocked)
        #expect(state.profiles[0].session?.proofs.isEmpty == true)
    }

    @Test func dueNagsTriggerLockUntilCleared() {
        let task = NagTask(title: "Dishes", startAt: Fixture.date(28, 18), now: Fixture.date(28, 8))
        let profile = LockProfile(name: "Nag lock", requirements: [UnlockRequirement(kind: .clearDueNags)], lockWhileNagsDue: true)
        var state = NagState(tasks: [task], profiles: [profile])

        LockMaintenance.run(&state, now: Fixture.date(28, 17), calendar: calendar)
        #expect(state.profiles[0].status == .off)

        LockMaintenance.run(&state, now: Fixture.date(28, 18, 1), calendar: calendar)
        #expect(state.profiles[0].session?.trigger == .nags)

        // Snoozing doesn't get you out.
        state.tasks[0].snooze(at: Fixture.date(28, 18, 2))
        LockMaintenance.run(&state, now: Fixture.date(28, 18, 3), calendar: calendar)
        #expect(state.profiles[0].isLocked)

        state.tasks[0].complete(at: Fixture.date(28, 18, 4), calendar: calendar)
        LockMaintenance.run(&state, now: Fixture.date(28, 18, 4), calendar: calendar)
        #expect(state.profiles[0].status == .off)
    }

    @Test func waitTimer() {
        let wait = UnlockRequirement(kind: .wait(minutes: 10))
        var profile = LockProfile(name: "Slow down", requirements: [wait])
        profile.lock(at: Fixture.date(28, 9))
        let state = NagState(profiles: [profile])
        #expect(!UnlockEvaluator.allMet(profile, state: state, steps: nil, now: Fixture.date(28, 10), calendar: calendar))

        profile.requestUnlock(at: Fixture.date(28, 10))
        let halfway = UnlockEvaluator.evaluate(profile, state: state, steps: nil, now: Fixture.date(28, 10, 5), calendar: calendar)
        #expect(halfway.first?.isMet == false)
        #expect(halfway.first?.progress == 0.5)
        #expect(UnlockEvaluator.allMet(profile, state: state, steps: nil, now: Fixture.date(28, 10, 10), calendar: calendar))
    }

    @Test func walkNeedsStepCounts() {
        var profile = LockProfile(name: "Walk", requirements: [UnlockRequirement(kind: .walk(steps: 1000))])
        profile.lock(at: Fixture.date(28, 9))
        let state = NagState(profiles: [profile])
        #expect(!UnlockEvaluator.allMet(profile, state: state, steps: nil, now: Fixture.date(28, 10), calendar: calendar))
        #expect(!UnlockEvaluator.allMet(profile, state: state, steps: 999, now: Fixture.date(28, 10), calendar: calendar))
        #expect(UnlockEvaluator.allMet(profile, state: state, steps: 1000, now: Fixture.date(28, 10), calendar: calendar))
    }

    @Test func phraseMatchingIsStrictAboutWords() {
        #expect(UnlockEvaluator.phraseMatches("  i choose   THIS ", "I choose this"))
        #expect(!UnlockEvaluator.phraseMatches("I choose", "I choose this"))
        #expect(!UnlockEvaluator.phraseMatches("", ""))
    }

    @Test func requiredNagsAreProtected() {
        let task = NagTask(title: "Meds", now: Fixture.date(28, 7))
        var profile = LockProfile(name: "Morning", requirements: [UnlockRequirement(kind: .completeTasks([task.id]))])
        var state = NagState(tasks: [task], profiles: [profile])
        #expect(!state.isTaskRequiredByEngagedLock(task.id))
        profile.lock(at: Fixture.date(28, 7))
        state.profiles = [profile]
        #expect(state.isTaskRequiredByEngagedLock(task.id))
    }

    @Test func emergencyUnlocksResetMonthly() {
        var state = NagState()
        state.settings.emergencyUnlocksPerMonth = 2
        state.settings.emergencyUnlocksUsed = [Fixture.date(1, 10), Fixture.date(30, 10, month: 9)]
        #expect(state.emergencyUnlocksLeft(at: Fixture.date(28, 10), calendar: calendar) == 1)
    }
}

struct UndoTests {
    let calendar = Fixture.calendar

    @Test func undoRestoresARepeatingNagsOccurrence() {
        var task = NagTask(title: "Meds", startAt: Fixture.date(28, 8), repeatRule: .daily, now: Fixture.date(27, 8))
        _ = task.snooze(at: Fixture.date(28, 8, 5))
        task.lastCompletedAt = Fixture.date(27, 9)
        let before = task

        task.complete(at: Fixture.date(28, 9), calendar: calendar)
        #expect(task.startAt == Fixture.date(29, 8))
        let didUndo = task.undoCompletion(at: Fixture.date(28, 9, 1))
        #expect(didUndo)
        #expect(task.startAt == before.startAt)
        #expect(task.snoozedUntil == before.snoozedUntil)
        #expect(task.snoozeCount == before.snoozeCount)
        #expect(task.lastCompletedAt == before.lastCompletedAt)
    }

    @Test func undoRestoresAOneOffCompletion() {
        var task = NagTask(title: "Taxes", startAt: Fixture.date(28, 8), now: Fixture.date(27, 8))
        task.complete(at: Fixture.date(28, 9), calendar: calendar)
        let didUndo = task.undoCompletion(at: Fixture.date(28, 9, 1))
        #expect(didUndo)
        #expect(task.completedAt == nil)
        #expect(!task.isFinished)
    }

    @Test func undoExpiresAfterTheWindow() {
        var task = NagTask(title: "Taxes", startAt: Fixture.date(28, 8), now: Fixture.date(27, 8))
        task.complete(at: Fixture.date(28, 9), calendar: calendar)
        let completed = task
        let tooLate = Fixture.date(28, 9).addingTimeInterval(NagUndo.window + 1)
        #expect(!task.canUndoCompletion(at: tooLate))
        let didUndo = task.undoCompletion(at: tooLate)
        #expect(!didUndo)
        #expect(task == completed)
    }

    @Test func undoAllowsSmallNegativeElapsedTimeFromClockSkew() {
        var task = NagTask(title: "Taxes", startAt: Fixture.date(28, 8), now: Fixture.date(27, 8))
        task.complete(at: Fixture.date(28, 9), calendar: calendar)

        #expect(task.canUndoCompletion(at: Fixture.date(28, 9).addingTimeInterval(-59)))
        #expect(!task.canUndoCompletion(at: Fixture.date(28, 9).addingTimeInterval(-60)))
    }

    @Test func onlyTheMostRecentCompletionCanBeUndone() {
        var task = NagTask(title: "Meds", startAt: Fixture.date(28, 8), repeatRule: .daily, now: Fixture.date(27, 8))
        task.complete(at: Fixture.date(28, 9), calendar: calendar)
        let didUndoFirst = task.undoCompletion(at: Fixture.date(28, 9, 1))
        #expect(didUndoFirst)
        let beforeSecondCompletion = task
        task.complete(at: Fixture.date(28, 9, 2), calendar: calendar)
        let didUndoSecond = task.undoCompletion(at: Fixture.date(28, 9, 3))
        #expect(didUndoSecond)
        #expect(task.startAt == beforeSecondCompletion.startAt)
        #expect(task.lastCompletedAt == beforeSecondCompletion.lastCompletedAt)
        let didUndoThird = task.undoCompletion(at: Fixture.date(28, 9, 4))
        #expect(!didUndoThird)
    }

    @Test func undoneNagIsNotSatisfiedForLocks() {
        var repeating = NagTask(title: "Meds", startAt: Fixture.date(28, 8), repeatRule: .daily, now: Fixture.date(27, 8))
        repeating.complete(at: Fixture.date(28, 9), calendar: calendar)
        let didUndoRepeating = repeating.undoCompletion(at: Fixture.date(28, 9, 1))
        #expect(didUndoRepeating)
        #expect(!repeating.isSatisfied(at: Fixture.date(28, 10), calendar: calendar))

        var oneOff = NagTask(title: "Taxes", startAt: Fixture.date(28, 8), now: Fixture.date(27, 8))
        oneOff.complete(at: Fixture.date(28, 9), calendar: calendar)
        let didUndoOneOff = oneOff.undoCompletion(at: Fixture.date(28, 9, 1))
        #expect(didUndoOneOff)
        #expect(!oneOff.isSatisfied(at: Fixture.date(28, 10), calendar: calendar))
    }

    @Test func mergeDoesNotRestoreAnUndoneCompletion_localFirst() {
        let (completed, undone) = completedAndUndoneCopies()
        let merged = TaskMerge.merge(undone, completed)
        #expect(merged.lastCompletedAt == nil)
        #expect(merged.completedAt == nil)
        #expect(merged.startAt == Fixture.date(28, 8))
    }

    @Test func mergeDoesNotRestoreAnUndoneCompletion_remoteFirst() {
        let (completed, undone) = completedAndUndoneCopies()
        let merged = TaskMerge.merge(completed, undone)
        #expect(merged.lastCompletedAt == nil)
        #expect(merged.completedAt == nil)
        #expect(merged.startAt == Fixture.date(28, 8))
    }

    @Test func mergeStillRestoresALaterCompletionAfterAnUndo() {
        let (_, undone) = completedAndUndoneCopies()
        var laterCompletion = undone
        laterCompletion.complete(at: Fixture.date(28, 9, 5), calendar: calendar)
        var staleEdit = undone
        staleEdit.title = "Edited elsewhere"
        staleEdit.updatedAt = Fixture.date(28, 9, 6)

        let merged = TaskMerge.merge(laterCompletion, staleEdit)
        #expect(merged.lastCompletedAt == Fixture.date(28, 9, 5))
        #expect(merged.startAt == Fixture.date(29, 8))
    }

    @Test func undoSurvivesALaterStaleEditOnTheOtherDevice() {
        let (completed, undone) = completedAndUndoneCopies()
        var staleEdit = completed
        staleEdit.title = "Edited elsewhere"
        staleEdit.notes = "Keep this newer edit"
        staleEdit.updatedAt = Fixture.date(28, 9, 2)

        for merged in [TaskMerge.merge(undone, staleEdit), TaskMerge.merge(staleEdit, undone)] {
            #expect(merged.title == staleEdit.title)
            #expect(merged.notes == staleEdit.notes)
            #expect(merged.startAt == undone.startAt)
            #expect(merged.lastCompletedAt == undone.lastCompletedAt)
            #expect(merged.completedAt == undone.completedAt)
            #expect(merged.snoozedUntil == undone.snoozedUntil)
            #expect(merged.snoozeCount == undone.snoozeCount)
            #expect(merged.completionUndo == undone.completionUndo)
            #expect(merged.undoneCompletionAt == undone.undoneCompletionAt)
        }
    }

    @Test func undoFieldsDecodeFromOlderPayloads() throws {
        let task = NagTask(title: "Old", startAt: Fixture.date(28, 9), repeatRule: .daily, now: Fixture.date(27, 9))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as! [String: Any]
        json.removeValue(forKey: "completionUndo")
        json.removeValue(forKey: "undoneCompletionAt")
        let decoded = try JSONDecoder().decode(NagTask.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == task)
        #expect(decoded.completionUndo == nil)
        #expect(decoded.undoneCompletionAt == nil)
    }

    private func completedAndUndoneCopies() -> (completed: NagTask, undone: NagTask) {
        var completed = NagTask(title: "Meds", startAt: Fixture.date(28, 8), repeatRule: .daily, now: Fixture.date(27, 8))
        completed.complete(at: Fixture.date(28, 9), calendar: calendar)
        var undone = completed
        _ = undone.undoCompletion(at: Fixture.date(28, 9, 1))
        return (completed, undone)
    }
}

struct TaskMergeTests {
    let now = Fixture.date(28, 12)

    @Test func newerEditWins() {
        var old = NagTask(title: "Old", now: Fixture.date(28, 8))
        var new = old
        new.title = "New"
        new.updatedAt = Fixture.date(28, 9)
        old.updatedAt = Fixture.date(28, 8)
        let merged = TaskMerge.merge(SyncedTasks(tasks: [old]), SyncedTasks(tasks: [new]), now: now)
        #expect(merged.tasks.map(\.title) == ["New"])
        #expect(TaskMerge.merge(SyncedTasks(tasks: [new]), SyncedTasks(tasks: [old]), now: now) == merged)
    }

    @Test func completionSurvivesALaterStaleEdit() {
        let base = NagTask(title: "Meds", startAt: Fixture.date(28, 8), now: Fixture.date(28, 7))
        var phone = base
        phone.complete(at: Fixture.date(28, 9), calendar: Fixture.calendar)
        var mac = base
        mac.snooze(at: Fixture.date(28, 9, 1))

        let merged = TaskMerge.merge(phone, mac)
        #expect(merged.isFinished)
        #expect(merged.snoozedUntil == nil)
        #expect(merged.completionUndo == phone.completionUndo)
        #expect(TaskMerge.merge(mac, phone) == merged)
    }

    @Test func deletionsSyncAndExpire() {
        let task = NagTask(title: "Gone", now: Fixture.date(28, 8))
        let local = SyncedTasks(tasks: [], deleted: [task.id.uuidString: Fixture.date(28, 9)])
        let remote = SyncedTasks(tasks: [task])
        #expect(TaskMerge.merge(local, remote, now: now).tasks.isEmpty)

        let muchLater = Fixture.date(28, 9).addingTimeInterval(TaskMerge.tombstoneLifetime + 1)
        #expect(TaskMerge.merge(local, SyncedTasks(), now: muchLater).deleted.isEmpty)
    }

    @Test func editAfterDeleteResurrects() {
        var task = NagTask(title: "Back", now: Fixture.date(28, 8))
        task.updatedAt = Fixture.date(28, 10)
        let local = SyncedTasks(tasks: [], deleted: [task.id.uuidString: Fixture.date(28, 9)])
        #expect(TaskMerge.merge(local, SyncedTasks(tasks: [task]), now: now).tasks.count == 1)
    }
}

struct StoreTests {
    @Test func updatePersistsAcrossInstances() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "nag-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SharedStore(directory: directory)
        store.update { $0.tasks.append(NagTask(title: "Persist me")) }
        #expect(SharedStore(directory: directory).load().tasks.map(\.title) == ["Persist me"])
    }

    @Test func fingerprintsAreStableAndDistinct() {
        #expect(KeyFingerprint.code("abc") == KeyFingerprint.code(" abc\n"))
        #expect(KeyFingerprint.code("abc") != KeyFingerprint.code("abd"))
        #expect(KeyFingerprint.nfc(Data([1, 2, 3])).hasPrefix("nfc:"))
        #expect(StableHash.hex("x") == StableHash.hex("x"))
    }

    @Test func formatting() {
        #expect(NagFormat.duration(45 * 60) == "45m")
        #expect(NagFormat.duration(80 * 60) == "1h 20m")
        #expect(NagFormat.duration(27 * 3600) == "1d 3h")
        #expect(NagFormat.minutes(90) == "1 hr 30 min")
        #expect(NagFormat.countdown(245) == "4:05")
    }
}
