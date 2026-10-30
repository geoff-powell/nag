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

enum DSTFixture {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    static func date(_ month: Int, _ day: Int, _ hour: Int, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
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

struct SnoozeOptionTests {
    @Test func snoozeOptionsHaveStableActionIdentifiers() {
        #expect(SnoozeOption.short.actionIdentifier == "SNOOZE_5")
        #expect(SnoozeOption.medium.actionIdentifier == "SNOOZE_15")
        #expect(SnoozeOption.long.actionIdentifier == "SNOOZE_60")
        for option in SnoozeOption.allCases {
            #expect(SnoozeOption.option(forAction: option.actionIdentifier) == option)
        }
        #expect(SnoozeOption.option(forAction: "SNOOZE") == nil)
        #expect(SnoozeOption.option(forAction: "UNKNOWN") == nil)
    }

    @Test func explicitSnoozeUsesTheChosenLength() {
        let now = Fixture.date(28, 9)
        var task = NagTask(title: "Laundry", startAt: Fixture.date(28, 8), now: Fixture.date(28, 8))
        let snoozed = task.snooze(at: now, minutes: 60)
        #expect(snoozed)
        #expect(task.snoozedUntil == Fixture.date(28, 10))
    }

    @Test func explicitSnoozeStillCountsAgainstTheLimit() {
        let now = Fixture.date(28, 9)
        var task = NagTask(
            title: "Laundry",
            startAt: Fixture.date(28, 8),
            style: NagStyle(maxSnoozes: 2),
            now: Fixture.date(28, 8)
        )
        let first = task.snooze(at: now, minutes: 5)
        let second = task.snooze(at: now, minutes: 15)
        let third = task.snooze(at: now, minutes: 60)
        #expect(first)
        #expect(second)
        #expect(!third)
        #expect(task.snoozesLeft == 0)
    }

    @Test func explicitSnoozeIsRefusedBeforeTheNagStarts() {
        var task = NagTask(title: "Later", startAt: Fixture.date(28, 18), now: Fixture.date(28, 8))
        let snoozed = task.snooze(at: Fixture.date(28, 9), minutes: 60)
        #expect(!snoozed)
    }

    @Test func defaultSnoozeStillUsesTheStyleLength() {
        let now = Fixture.date(28, 9)
        let style = NagStyle(snoozeMinutes: 15)
        var defaultTask = NagTask(title: "Laundry", startAt: Fixture.date(28, 8), style: style, now: Fixture.date(28, 8))
        var explicitTask = defaultTask
        let defaultSnoozed = defaultTask.snooze(at: now)
        let explicitSnoozed = explicitTask.snooze(at: now, minutes: style.snoozeMinutes)
        #expect(defaultSnoozed)
        #expect(explicitSnoozed)
        #expect(defaultTask.snoozedUntil == explicitTask.snoozedUntil)
    }
}

struct StartedTests {
    let calendar = Fixture.calendar

    @Test func startingSilencesNaggingForTheWorkingWindow() {
        var task = NagTask(title: "Laundry", startAt: Fixture.date(28, 8), style: NagStyle(workMinutes: 30), now: Fixture.date(28, 7))
        task.start(at: Fixture.date(28, 9))
        #expect(task.nagStart == Fixture.date(28, 9, 30))
        #expect(!task.isNagging(at: Fixture.date(28, 9, 29)))
        #expect(task.isNagging(at: Fixture.date(28, 9, 30)))
    }

    @Test func startingDoesNotUseASnooze() {
        var task = NagTask(title: "Laundry", startAt: Fixture.date(28, 8), style: NagStyle(maxSnoozes: 2), now: Fixture.date(28, 7))
        task.start(at: Fixture.date(28, 9))
        #expect(task.snoozeCount == 0)
        #expect(task.snoozesLeft == 2)
        #expect(task.canSnooze(at: Fixture.date(28, 9)))
    }

    @Test func startedNagIsStillDueForLocks() {
        let now = Fixture.date(28, 9)
        var task = NagTask(title: "Laundry", startAt: Fixture.date(28, 8), now: Fixture.date(28, 7))
        task.start(at: now)
        #expect(!task.isSatisfied(at: now, calendar: calendar))
        #expect(task.canComplete(at: now, calendar: calendar))
        #expect(task.isOutstanding(at: now))
        var profile = LockProfile(name: "Focus", requirements: [UnlockRequirement(kind: .clearDueNags)])
        profile.status = .locked(LockSession(startedAt: now))
        let status = UnlockEvaluator.evaluate(profile, state: NagState(tasks: [task]), steps: nil, now: now, calendar: calendar)
        #expect(status.first?.isMet == false)
    }

    @Test func completingClearsStarted() {
        var task = NagTask(title: "Laundry", startAt: Fixture.date(28, 8), now: Fixture.date(28, 7))
        task.start(at: Fixture.date(28, 9))
        task.complete(at: Fixture.date(28, 10), calendar: calendar)
        #expect(task.startedAt == nil)
    }

    @Test func movingToANewOccurrenceClearsStarted() {
        var task = NagTask(title: "Laundry", startAt: Fixture.date(28, 8), repeatRule: .daily, now: Fixture.date(28, 7))
        task.start(at: Fixture.date(28, 9))
        task.startAt = Fixture.date(29, 8)
        #expect(!task.isStarted(at: Fixture.date(29, 9)))
    }

    @Test func nagStartIgnoresAStartedAtEarlierThanStartAt() {
        var task = NagTask(title: "Laundry", startAt: Fixture.date(29, 8), now: Fixture.date(28, 7))
        task.startedAt = Fixture.date(28, 9)
        #expect(task.workingUntil() == nil)
        #expect(task.nagStart == Fixture.date(29, 8))
    }

    @Test func checkInsUseTheBaseIntervalWithNoEscalation() {
        var task = NagTask(title: "Laundry", startAt: Fixture.date(28, 8), style: NagStyle(intervalMinutes: 15, escalation: .relentless, workMinutes: 30), now: Fixture.date(28, 7))
        task.start(at: Fixture.date(28, 9))
        let plan = NagPlanner(calendar: calendar).plan(tasks: [task], quietHours: QuietHours(), now: Fixture.date(28, 9, 31))
        #expect(plan.notifications.first?.trigger == .every(seconds: 900))
    }

    @Test func checkInWordingIsCalm() {
        var task = NagTask(title: "Laundry", startAt: Fixture.date(28, 8), style: NagStyle(workMinutes: 30), now: Fixture.date(28, 7))
        task.start(at: Fixture.date(28, 9))
        let plan = NagPlanner(calendar: calendar).plan(tasks: [task], quietHours: QuietHours(), now: Fixture.date(28, 9, 31))
        #expect(plan.notifications.first?.body == NagMessages.checkInRepeatingBody(title: task.title))
        #expect(plan.notifications.first?.body.lowercased().contains("overdue") == false)
    }

    @Test func startingChangesTheNotificationIdentifier() {
        let now = Fixture.date(28, 9)
        var task = NagTask(title: "Laundry", startAt: Fixture.date(28, 8), style: NagStyle(workMinutes: 0), now: Fixture.date(28, 7))
        let planner = NagPlanner(calendar: calendar)
        let before = planner.plan(tasks: [task], quietHours: QuietHours(), now: now)
        task.start(at: now)
        let after = planner.plan(tasks: [task], quietHours: QuietHours(), now: now)
        #expect(before.notifications.first?.identifier != after.notifications.first?.identifier)
    }

    @Test func plannerWakesWhenTheWorkingWindowEnds() {
        var task = NagTask(title: "Laundry", startAt: Fixture.date(28, 8), style: NagStyle(workMinutes: 30), now: Fixture.date(28, 7))
        task.start(at: Fixture.date(28, 9))
        let plan = NagPlanner(calendar: calendar).plan(tasks: [task], quietHours: QuietHours(), now: Fixture.date(28, 9, 1))
        #expect(plan.nextWake == Fixture.date(28, 9, 30))
    }

    @Test func nagStyleDecodesWithoutWorkMinutes() throws {
        let style = NagStyle(intervalMinutes: 5, escalation: .relentless, snoozeMinutes: 15, maxSnoozes: nil, breakThroughFocus: false, workMinutes: 45)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(style)) as! [String: Any]
        json.removeValue(forKey: "workMinutes")
        let decoded = try JSONDecoder().decode(NagStyle.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.workMinutes == 30)
        #expect(decoded.intervalMinutes == style.intervalMinutes)
        #expect(decoded.escalation == style.escalation)
        #expect(decoded.snoozeMinutes == style.snoozeMinutes)
        #expect(decoded.maxSnoozes == nil)
        #expect(decoded.breakThroughFocus == style.breakThroughFocus)
    }

    @Test func nagStyleDecodesMainUnlimitedAndLimitedPayloads() throws {
        let unlimited = Data(#"{"intervalMinutes":5,"escalation":"relentless","snoozeMinutes":15,"breakThroughFocus":false}"#.utf8)
        let unlimitedStyle = try JSONDecoder().decode(NagStyle.self, from: unlimited)
        #expect(unlimitedStyle.maxSnoozes == nil)
        #expect(unlimitedStyle.workMinutes == 30)

        let limited = Data(#"{"intervalMinutes":5,"escalation":"relentless","snoozeMinutes":15,"maxSnoozes":2,"breakThroughFocus":false}"#.utf8)
        #expect(try JSONDecoder().decode(NagStyle.self, from: limited).maxSnoozes == 2)
    }

    @Test func nagStyleClampsDecodedWorkMinutes() throws {
        let tooShort = Data(#"{"workMinutes":0}"#.utf8)
        let tooLong = Data(#"{"workMinutes":1441}"#.utf8)
        #expect(try JSONDecoder().decode(NagStyle.self, from: tooShort).workMinutes == 1)
        #expect(try JSONDecoder().decode(NagStyle.self, from: tooLong).workMinutes == 1440)
    }

    @Test func startedAtDecodesFromOlderPayloads() throws {
        let task = NagTask(title: "Old", startAt: Fixture.date(28, 9), now: Fixture.date(27, 9))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as! [String: Any]
        json.removeValue(forKey: "startedAt")
        let decoded = try JSONDecoder().decode(NagTask.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.startedAt == nil)
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

    @Test func customRuleCoversSpecificDaysAndSeveralTimesADay() {
        let task = meds()
        let occurrences = sequence(first: Fixture.date(28, 8)) {
            task.occurrence(after: $0, calendar: calendar)
        }.dropFirst().prefix(5)
        #expect(Array(occurrences) == [
            Fixture.date(28, 9), Fixture.date(29, 23), Fixture.date(30, 9),
            Fixture.date(2, 9, month: 11), Fixture.date(3, 23, month: 11),
        ])
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

@Suite struct RepeatRuleTests {
    private enum OldRepeatRule: String, Decodable {
        case never, daily, weekdays, weekly, custom
    }

    private struct OldTask: Decodable {
        let repeatRule: OldRepeatRule
    }

    @Test func newRulesRoundTripThroughJSON() throws {
        var every = NagTask(title: "Water plants", repeatRule: .everyNDays, repeatEvery: 17)
        every.monthDay = 9
        let monthly = NagTask(title: "Rent", repeatRule: .monthly, monthDay: 31)
        for task in [every, monthly] {
            #expect(try JSONDecoder().decode(NagTask.self, from: JSONEncoder().encode(task)) == task)
        }
    }

    @Test func newRulesEncodeALegacySafeRepeatRule() throws {
        for rule in [RepeatRule.everyNDays, .monthly] {
            let task = NagTask(title: "Safe", repeatRule: rule)
            let data = try JSONEncoder().encode(task)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["repeatRule"] as? String == "daily")
            #expect(json["repeatKind"] as? String == rule.rawValue)
            #expect(try JSONDecoder().decode(OldTask.self, from: data).repeatRule == .daily)
        }
    }

    @Test func aPayloadWithAnUnknownRuleDecodesAsDaily() throws {
        let task = NagTask(title: "Future", repeatRule: .monthly)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
        json["repeatKind"] = "yearly"
        let decoded = try JSONDecoder().decode(NagTask.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.repeatRule == .daily)
    }

    @Test func syncedTasksSurviveAnUndecodableFutureRule() throws {
        let synced = SyncedTasks(tasks: [NagTask(title: "Future")])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(synced)) as? [String: Any])
        var tasks = try #require(json["tasks"] as? [[String: Any]])
        tasks[0]["repeatKind"] = "yearly"
        json["tasks"] = tasks
        let decoded = try JSONDecoder().decode(SyncedTasks.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.tasks.count == 1)
        #expect(decoded.tasks[0].repeatRule == .daily)
    }

    @Test func oldPayloadsWithoutRepeatKindStillDecode() throws {
        let task = NagTask(title: "Old", startAt: Fixture.date(28, 9), repeatRule: .daily)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
        json.removeValue(forKey: "repeatKind")
        json.removeValue(forKey: "repeatEvery")
        json.removeValue(forKey: "monthDay")
        let decoded = try JSONDecoder().decode(NagTask.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.repeatRule == .daily)
        #expect(decoded.repeatEvery == 2)
        #expect(decoded.monthDay == 28)
    }

    /// Every device must derive the same day from the same payload, whatever its time zone.
    @Test func missingMonthDayIsDerivedInUTC() throws {
        let task = NagTask(title: "Old", startAt: Fixture.date(31, 23, 30), repeatRule: .daily)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
        json.removeValue(forKey: "monthDay")
        let decoded = try JSONDecoder().decode(NagTask.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.monthDay == 31)
    }

    @Test func hasValidScheduleRejectsZeroNAndDayThirtyTwo() {
        var task = NagTask(title: "Invalid", repeatRule: .everyNDays)
        task.repeatEvery = 0
        #expect(!task.hasValidSchedule)
        task.repeatRule = .monthly
        task.monthDay = 32
        #expect(!task.hasValidSchedule)
    }

    @Test func newRuleLabelsAndDuplicatesKeepTheirParameters() {
        let every = NagTask(title: "Water", repeatRule: .everyNDays, repeatEvery: 3)
        let everyCopy = every.duplicate(now: Fixture.date(28, 10))
        #expect(every.repeatLabel == "Every 3 days")
        #expect(everyCopy.repeatRule == .everyNDays)
        #expect(everyCopy.repeatEvery == 3)

        let monthly = NagTask(title: "Rent", repeatRule: .monthly, monthDay: 31)
        let monthlyCopy = monthly.duplicate(now: Fixture.date(28, 10))
        #expect(monthly.repeatLabel == "Monthly on the 31st")
        #expect(monthlyCopy.repeatRule == .monthly)
        #expect(monthlyCopy.monthDay == 31)
    }
}

@Suite struct EveryNDaysTests {
    let calendar = Fixture.calendar

    @Test func everyThreeDaysStepsByThree() {
        let task = NagTask(title: "Water", startAt: Fixture.date(1, 8), repeatRule: .everyNDays, repeatEvery: 3)
        #expect(task.occurrence(after: Fixture.date(1, 8), calendar: calendar) == Fixture.date(4, 8))
        #expect(task.occurrence(after: Fixture.date(4, 8), calendar: calendar) == Fixture.date(7, 8))
        #expect(task.occurrence(after: Fixture.date(7, 8), calendar: calendar) == Fixture.date(10, 8))
    }

    @Test func everyNDaysWorksBeyondTheOldFifteenDayLimit() {
        for interval in [20, 45] {
            let task = NagTask(title: "Long", startAt: Fixture.date(1, 8), repeatRule: .everyNDays, repeatEvery: interval)
            let expected = calendar.date(byAdding: .day, value: interval, to: Fixture.date(1, 8))
            #expect(task.occurrence(after: Fixture.date(1, 8), calendar: calendar) == expected)
        }
    }

    @Test func everyNDaysKeepsWallClockTimeAcrossDST() {
        let calendar = DSTFixture.calendar
        let task = NagTask(title: "DST", startAt: DSTFixture.date(3, 27, 9), repeatRule: .everyNDays, repeatEvery: 3)
        let next = task.occurrence(after: DSTFixture.date(3, 27, 9), calendar: calendar)
        #expect(next == DSTFixture.date(3, 30, 9))
        #expect(next.map { calendar.component(.hour, from: $0) } == 9)
    }

    @Test func everyNDaysFromAnOverdueAnchor() {
        let task = NagTask(title: "Overdue", startAt: Fixture.date(1, 8), repeatRule: .everyNDays, repeatEvery: 3)
        #expect(task.occurrence(after: Fixture.date(28, 9), calendar: calendar) == Fixture.date(31, 8))
    }

    @Test func completingAnEveryNDaysNagLateSkipsMissedOccurrences() {
        var task = NagTask(title: "Water", startAt: Fixture.date(1, 8), repeatRule: .everyNDays, repeatEvery: 3)
        task.complete(at: Fixture.date(28, 9), calendar: calendar)
        #expect(task.startAt == Fixture.date(31, 8))
        #expect(task.isSatisfied(at: Fixture.date(28, 12), calendar: calendar))
        #expect(!task.canComplete(at: Fixture.date(28, 12), calendar: calendar))
    }
}

@Suite struct MonthlyTests {
    let calendar = Fixture.calendar

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 8) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func monthlyKeepsTheOriginalDayAcrossShortMonths() {
        for year in [2025, 2024] {
            let january = date(year, 1, 31)
            let task = NagTask(title: "Month end", startAt: january, repeatRule: .monthly, monthDay: 31)
            let februaryDay = year == 2024 ? 29 : 28
            let february = task.occurrence(after: january, calendar: calendar)
            #expect(february == date(year, 2, februaryDay))
            #expect(february.flatMap { task.occurrence(after: $0, calendar: calendar) } == date(year, 3, 31))
        }
    }

    @Test func monthlyOnTheFirstIsStable() {
        let task = NagTask(title: "First", startAt: date(2026, 1, 1), repeatRule: .monthly, monthDay: 1)
        #expect(task.occurrence(after: date(2026, 1, 1), calendar: calendar) == date(2026, 2, 1))
    }

    @Test func monthlyAcrossAYearBoundary() {
        let task = NagTask(title: "Year", startAt: date(2026, 12, 15), repeatRule: .monthly, monthDay: 15)
        #expect(task.occurrence(after: date(2026, 12, 15), calendar: calendar) == date(2027, 1, 15))
    }

    @Test func monthlyKeepsWallClockTimeAcrossDST() {
        let calendar = DSTFixture.calendar
        let task = NagTask(title: "DST", startAt: DSTFixture.date(3, 28, 9), repeatRule: .monthly, monthDay: 28)
        let next = task.occurrence(after: DSTFixture.date(3, 28, 9), calendar: calendar)
        #expect(next == DSTFixture.date(4, 28, 9))
        #expect(next.map { calendar.component(.hour, from: $0) } == 9)
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

@Suite struct NagToneTests {
    let planner = NagPlanner(calendar: Fixture.calendar)

    @Test func standardToneKeepsTheCurrentWordingVerbatim() {
        #expect(NagMessages.body(
            title: "Laundry",
            notes: "",
            number: 3,
            overdue: 0,
            tone: .standard
        ) == "Nag #3. Now's a good moment.")
        #expect(NagMessages.repeatingBody(
            title: "Laundry",
            tier: 3,
            tone: .standard
        ) == "I'm not going to stop until this is done.")
    }

    @Test func everyToneOffersANextStepAtEveryTier() {
        let overdue: [TimeInterval] = [0, 15 * 60, 60 * 60, 3 * 60 * 60]
        for tone in NagTone.allCases {
            #expect(!NagMessages.body(
                title: "Laundry",
                notes: "",
                number: 1,
                overdue: 0,
                tone: tone
            ).isEmpty)
            for (tier, duration) in overdue.enumerated() {
                #expect(!NagMessages.body(
                    title: "Laundry",
                    notes: "",
                    number: tier + 2,
                    overdue: duration,
                    tone: tone
                ).isEmpty)
                #expect(!NagMessages.repeatingBody(
                    title: "Laundry",
                    tier: tier,
                    tone: tone
                ).isEmpty)
            }
        }
    }

    @Test func gentleIsNeverThreatening() {
        let gentle = NagMessages.repeatingBody(title: "Laundry", tier: 3, tone: .gentle)
        #expect(!gentle.lowercased().contains("not going to stop"))
        #expect(!gentle.lowercased().contains("excuses"))
        #expect(gentle != NagMessages.repeatingBody(title: "Laundry", tier: 3, tone: .standard))
        #expect(gentle != NagMessages.repeatingBody(title: "Laundry", tier: 3, tone: .pushy))
    }

    @Test func pushyIsBlunter() {
        let pushy = NagMessages.repeatingBody(title: "Laundry", tier: 3, tone: .pushy)
        #expect(pushy == "Do it now. One tiny step, no excuses.")
        #expect(pushy != NagMessages.repeatingBody(title: "Laundry", tier: 3, tone: .standard))
        #expect(pushy != NagMessages.repeatingBody(title: "Laundry", tier: 3, tone: .gentle))
    }

    @Test func perNagToneOverridesTheGlobalTone() {
        let task = NagTask(
            title: "Laundry",
            startAt: Fixture.date(28, 8),
            style: NagStyle(tone: .pushy),
            now: Fixture.date(28, 7)
        )
        let plan = planner.plan(
            tasks: [task],
            quietHours: QuietHours(),
            tone: .gentle,
            now: Fixture.date(28, 12)
        )
        #expect(plan.notifications.first?.body
            == NagMessages.repeatingBody(title: task.title, tier: 3, tone: .pushy))
    }

    @Test func toneChangesTheContentKey() {
        let task = NagTask(
            title: "Laundry",
            startAt: Fixture.date(28, 8),
            now: Fixture.date(28, 7)
        )
        let gentle = planner.plan(
            tasks: [task],
            quietHours: QuietHours(),
            tone: .gentle,
            now: Fixture.date(28, 9)
        )
        let pushy = planner.plan(
            tasks: [task],
            quietHours: QuietHours(),
            tone: .pushy,
            now: Fixture.date(28, 9)
        )
        #expect(gentle.notifications.first?.identifier != pushy.notifications.first?.identifier)
    }

    @Test func tierBoundariesAreUnchangedByTone() {
        let overdue: [TimeInterval] = [0, 899, 900, 3_599, 3_600, 10_799, 10_800]
        for tone in NagTone.allCases {
            #expect(overdue.map(NagMessages.tier(overdue:)) == [0, 0, 1, 1, 2, 2, 3])
            #expect(overdue.map(NagMessages.nextTierChange(overdue:))
                == [900, 900, 3_600, 3_600, 10_800, 10_800, nil])
            #expect(!NagMessages.repeatingBody(title: "Laundry", tier: 0, tone: tone).isEmpty)
        }
    }

    @Test func unknownToneRawValueDecodesAsNoOverride() throws {
        let data = Data("""
        {
          "intervalMinutes": 15,
          "escalation": "gentle",
          "snoozeMinutes": 10,
          "maxSnoozes": 3,
          "breakThroughFocus": true,
          "workMinutes": 30,
          "tone": "sarcastic"
        }
        """.utf8)
        let style = try JSONDecoder().decode(NagStyle.self, from: data)
        #expect(style.tone == nil)
    }

    @Test func syncedTasksSurviveAnUnknownTone() throws {
        let synced = SyncedTasks(tasks: [NagTask(title: "Laundry")])
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(synced)) as? [String: Any]
        )
        var tasks = try #require(json["tasks"] as? [[String: Any]])
        var style = try #require(tasks[0]["style"] as? [String: Any])
        style["tone"] = "sarcastic"
        tasks[0]["style"] = style
        json["tasks"] = tasks

        let decoded = try JSONDecoder().decode(
            SyncedTasks.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        #expect(decoded.tasks.count == 1)
        #expect(decoded.tasks.first?.style.tone == nil)
    }

    @Test func settingsDecodeWithoutNagTone() throws {
        let settings = AppSettings(nagTone: .pushy)
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
        )
        json.removeValue(forKey: "nagTone")
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        #expect(decoded.nagTone == .standard)
    }

    @Test func toneAlsoAppliesToCheckInWording() {
        let gentle = NagMessages.checkInRepeatingBody(title: "Laundry", tone: .gentle)
        let standard = NagMessages.checkInRepeatingBody(title: "Laundry", tone: .standard)
        let pushy = NagMessages.checkInRepeatingBody(title: "Laundry", tone: .pushy)
        #expect(gentle != standard)
        #expect(pushy != standard)
        #expect(gentle.lowercased().contains("small next step"))
        #expect(pushy.lowercased().contains("next step"))
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

    @Test func undoRestoresStartedState() {
        var task = NagTask(title: "Meds", startAt: Fixture.date(28, 8), repeatRule: .daily, now: Fixture.date(27, 8))
        task.start(at: Fixture.date(28, 8, 30))
        let startedAt = task.startedAt
        task.complete(at: Fixture.date(28, 9), calendar: calendar)
        #expect(task.startedAt == nil)
        let didUndo = task.undoCompletion(at: Fixture.date(28, 9, 1))
        #expect(didUndo)
        #expect(task.startedAt == startedAt)
        #expect(task.isStarted(at: Fixture.date(28, 9, 1)))
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
            #expect(merged.startedAt == undone.startedAt)
            #expect(merged.completionUndo == undone.completionUndo)
            #expect(merged.undoneCompletionAt == undone.undoneCompletionAt)
        }
    }

    @Test func undoFieldsDecodeFromOlderPayloads() throws {
        var task = NagTask(title: "Old", startAt: Fixture.date(28, 9), repeatRule: .daily, now: Fixture.date(27, 9))
        task.start(at: Fixture.date(28, 9))
        task.complete(at: Fixture.date(28, 10), calendar: calendar)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as! [String: Any]
        json.removeValue(forKey: "undoneCompletionAt")
        var undo = json["completionUndo"] as! [String: Any]
        undo.removeValue(forKey: "startedAt")
        json["completionUndo"] = undo
        let decoded = try JSONDecoder().decode(NagTask.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.completionUndo?.startedAt == nil)
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
        phone.start(at: Fixture.date(28, 8, 30))
        phone.complete(at: Fixture.date(28, 9), calendar: Fixture.calendar)
        var mac = base
        mac.start(at: Fixture.date(28, 8, 45))
        mac.snooze(at: Fixture.date(28, 9, 1))

        let merged = TaskMerge.merge(phone, mac)
        #expect(merged.isFinished)
        #expect(merged.snoozedUntil == nil)
        #expect(!merged.isStarted(at: Fixture.date(28, 9, 1)))
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
