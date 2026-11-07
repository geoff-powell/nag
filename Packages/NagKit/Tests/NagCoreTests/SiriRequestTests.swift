import Foundation
import Testing
@testable import NagCore

/// Creating a nag in one Siri request (#49): presets, spoken starts and Siri's recurrence rules.
struct SiriRequestTests {
    let calendar = Fixture.calendar
    /// Wednesday 28 October 2026, 10:00 UTC.
    let now = Fixture.date(28, 10)

    // MARK: - Presets

    @Test func presetSetsTheStyleAndExplicitValuesWin() throws {
        let key = UnlockKey(name: "Pill box", kind: .code, fingerprint: "fingerprint")
        var state = NagState(keys: [key])

        let task = try state.apply(
            NagRequest(title: "Take meds", preset: .medication, intervalMinutes: 7),
            now: now,
            calendar: calendar
        ).task

        #expect(task.style.intervalMinutes == 7)
        #expect(task.style.escalation == .relentless)
        #expect(task.style.maxSnoozes == 1)
        #expect(task.proof == .scanKey(key.id))
        #expect(state.tasks == [task])
    }

    @Test func explicitEscalationAndSnoozesOverrideThePreset() throws {
        var state = NagState()
        let request = NagRequest(title: "Bins", preset: .appointment, escalation: .gentle, snoozeLimit: .unlimited)

        let task = try state.apply(request, now: now, calendar: calendar).task

        #expect(task.style.intervalMinutes == NagPreset.appointment.style.intervalMinutes)
        #expect(task.style.escalation == .gentle)
        #expect(task.style.maxSnoozes == nil)
    }

    @Test func resendingARequestWithAPresetChangesNothing() throws {
        var state = NagState()
        let request = NagRequest(title: "Pills", preset: .chore, source: "Shortcuts", externalID: "pills")
        try state.apply(request, now: now, calendar: calendar)
        let before = state

        let again = try state.apply(request, now: Fixture.date(28, 12), calendar: calendar)

        #expect(!again.isNew)
        #expect(state == before)
    }

    @Test func aPresetOnAnUpdateRestylesTheNag() throws {
        var state = NagState()
        try state.apply(NagRequest(title: "Pills", source: "Shortcuts", externalID: "pills"), now: now, calendar: calendar)

        let updated = try state.apply(
            NagRequest(title: "Pills", preset: .someday, source: "Shortcuts", externalID: "pills"),
            now: Fixture.date(28, 11),
            calendar: calendar
        )

        #expect(state.tasks.count == 1)
        #expect(updated.task.style.intervalMinutes == 60)
        #expect(state.tasks[0].updatedAt == Fixture.date(28, 11))
    }

    // MARK: - Spoken starts

    private func start(_ answer: String) throws -> Date? {
        try SpokenStart.date(from: answer, now: now, calendar: calendar)
    }

    @Test(arguments: ["", "   ", "now", "Now.", "right now", "start now", "Immediately!", "now please", "today", "skip"])
    func blankOrNowStartsNow(answer: String) throws {
        #expect(try start(answer) == nil)
    }

    @Test(arguments: [
        ("in 20 minutes", 20),
        ("In 20 mins.", 20),
        ("in an hour", 60),
        ("in half an hour", 30),
        ("in an hour and a half", 90),
        ("in 1h30m", 90),
        ("in twenty five minutes", 25),
        ("in 2 hours and 15 minutes", 135),
        ("in 1.5 hours", 90),
        ("in a couple of hours", 120),
    ])
    func delaysCountFromNow(answer: String, minutes: Int) throws {
        #expect(try start(answer) == now.addingTimeInterval(TimeInterval(minutes * 60)))
    }

    @Test(arguments: [
        // 8 AM has gone, so a bare 8 is tonight.
        ("8", Fixture.date(28, 20)),
        ("at 8", Fixture.date(28, 20)),
        ("eight", Fixture.date(28, 20)),
        ("11", Fixture.date(28, 11)),
        ("10", Fixture.date(28, 10)),
        ("at 9:30", Fixture.date(28, 21, 30)),
        ("8 PM", Fixture.date(28, 20)),
        ("8 p.m.", Fixture.date(28, 20)),
        ("8pm", Fixture.date(28, 20)),
        ("8:15pm", Fixture.date(28, 20, 15)),
        ("eight thirty", Fixture.date(28, 20, 30)),
        ("eight forty five PM", Fixture.date(28, 20, 45)),
        ("8 o'clock", Fixture.date(28, 20)),
        ("8 AM", Fixture.date(29, 8)),
        ("17:30", Fixture.date(28, 17, 30)),
        ("noon", Fixture.date(28, 12)),
        ("at midnight", Fixture.date(29, 0)),
        ("tomorrow", Fixture.date(29, 9)),
        ("tomorrow morning", Fixture.date(29, 9)),
        ("tomorrow at 8", Fixture.date(29, 8)),
        ("8 tomorrow", Fixture.date(29, 8)),
        ("tomorrow at 8 pm", Fixture.date(29, 20)),
        // On another day, an hour alone is in waking hours.
        ("tomorrow at 7", Fixture.date(29, 7)),
        ("tomorrow at 12", Fixture.date(29, 12)),
        ("tomorrow at 3", Fixture.date(29, 15)),
        ("tomorrow morning at 6", Fixture.date(29, 6)),
        ("friday", Fixture.date(30, 9)),
        ("on Friday at 5", Fixture.date(30, 17)),
        ("next monday at 8:30", Fixture.date(2, 8, 30, month: 11)),
        // Today is Wednesday: 9 AM has gone, 4 PM hasn't.
        ("wednesday", Fixture.date(4, 9, month: 11)),
        ("wednesday at 4", Fixture.date(28, 16)),
        ("tonight at 7", Fixture.date(28, 19)),
        ("tonight at 12", Fixture.date(29, 0)),
        ("this evening at 6:30", Fixture.date(28, 18, 30)),
        ("starting at 3 in the afternoon", Fixture.date(28, 15)),
    ])
    func clockTimesAreTheNextTimeTheyComeRound(answer: String, expected: Date) throws {
        #expect(try start(answer) == expected)
    }

    @Test func unreadableAnswersThrowWithTheAnswer() {
        #expect(throws: NagRequestError.invalidValue(parameter: "start time", value: "after lunch")) {
            try start(" after lunch ")
        }
        #expect(throws: NagRequestError.self) { try start("25:00") }
        #expect(throws: NagRequestError.self) { try start("in a while") }
        #expect(throws: NagRequestError.self) { try start("in nan minutes") }
    }

    @Test func otherDatesUseTheSystemsDateDetection() throws {
        // Date detection works from the real clock and time zone.
        let calendar = Calendar.current
        let date = try #require(try SpokenStart.date(from: "the day after tomorrow at 5 PM", now: .now, calendar: calendar))
        let expectedDay = try #require(calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: .now)))
        #expect(calendar.startOfDay(for: date) == expectedDay)
        #expect(calendar.component(.hour, from: date) == 17)
    }

    @Test func detectedDatesThatHavePassedThrow() {
        #expect(throws: NagRequestError.invalidValue(parameter: "start time", value: "yesterday")) {
            try SpokenStart.date(from: "yesterday", now: .now, calendar: .current)
        }
    }

    // MARK: - Siri's date components

    @Test(arguments: [
        (DateComponents(hour: 8), Fixture.date(29, 8)),
        (DateComponents(hour: 20, minute: 30), Fixture.date(28, 20, 30)),
        (DateComponents(hour: 10), Fixture.date(28, 10)),
        (DateComponents(year: 2026, month: 11, day: 2, hour: 7, minute: 45), Fixture.date(2, 7, 45, month: 11)),
        (DateComponents(year: 2026, month: 11, day: 2), Fixture.date(2, 9, month: 11)),
        (DateComponents(weekday: 6), Fixture.date(30, 9)),
        (DateComponents(month: 12, day: 25), Fixture.date(25, 9, month: 12)),
    ])
    func dateComponentsBecomeTheNextMatchingStart(components: DateComponents, expected: Date) throws {
        #expect(try SpokenStart.date(from: components, now: now, calendar: calendar) == expected)
    }

    @Test func aDayWithoutATimeTakesTheRepeatsTime() throws {
        let day = DateComponents(year: 2026, month: 10, day: 30)
        let rule = Calendar.RecurrenceRule.daily(calendar: calendar, hours: [20], minutes: [15])

        let startAt = try SpokenStart.date(from: day, repeating: rule, now: now, calendar: calendar)
        var request = NagRequest(title: "Stretch", startAt: startAt)
        try request.setRepeat(rule, now: now, calendar: calendar)

        #expect(startAt == Fixture.date(30, 20, 15))
        #expect(request.repeatRule == .daily)
        #expect(request.startAt == Fixture.date(30, 20, 15))
        // Several times a day leave the day's start at 9 AM.
        let twice = Calendar.RecurrenceRule.daily(calendar: calendar, hours: [9, 21])
        #expect(try SpokenStart.date(from: day, repeating: twice, now: now, calendar: calendar) == Fixture.date(30, 9))
    }

    @Test func dateComponentsUseTheirOwnTimeZone() throws {
        var components = DateComponents(year: 2026, month: 10, day: 29, hour: 9)
        components.timeZone = TimeZone(identifier: "America/New_York")
        // 9 AM in New York is 13:00 UTC (daylight saving time is still on).
        #expect(try SpokenStart.date(from: components, now: now, calendar: calendar) == Fixture.date(29, 13))
    }

    // MARK: - Recurrence rules

    private func request(_ rule: Calendar.RecurrenceRule, startAt: Date? = nil) throws -> NagRequest {
        var request = NagRequest(title: "Repeat", startAt: startAt)
        try request.setRepeat(rule, now: now, calendar: calendar)
        return request
    }

    /// A custom time without its random ID, to compare schedules.
    private struct Slot: Equatable {
        var minute: Int
        var weekdays: Set<Int>
    }

    private func schedule(_ times: [NagTime]?) -> [Slot] {
        (times ?? []).map { Slot(minute: $0.minute, weekdays: $0.weekdays) }
    }

    @Test func simpleRulesMapToNagsRepeats() throws {
        let weekdays: [Calendar.RecurrenceRule.Weekday] = [.every(.monday), .every(.tuesday), .every(.wednesday), .every(.thursday), .every(.friday)]
        let everyDay: [Calendar.RecurrenceRule.Weekday] = weekdays + [.every(.saturday), .every(.sunday)]

        #expect(try request(.daily(calendar: calendar)).repeatRule == .daily)
        #expect(try request(.weekly(calendar: calendar)).repeatRule == .weekly)
        #expect(try request(.weekly(calendar: calendar, weekdays: weekdays)).repeatRule == .weekdays)
        #expect(try request(.daily(calendar: calendar, weekdays: weekdays)).repeatRule == .weekdays)
        #expect(try request(.weekly(calendar: calendar, weekdays: everyDay)).repeatRule == .daily)

        let everyThreeDays = try request(.daily(calendar: calendar, interval: 3))
        #expect(everyThreeDays.repeatRule == .everyNDays)
        #expect(everyThreeDays.repeatEvery == 3)

        // On the start's own weekday, weekly is Nag's weekly repeat.
        #expect(try request(.weekly(calendar: calendar, weekdays: [.every(.wednesday)])).repeatRule == .weekly)
        let thursdays = try request(.weekly(calendar: calendar, weekdays: [.every(.thursday)], hours: [9]))
        #expect(thursdays.repeatRule == .weekly)
        #expect(thursdays.startAt == Fixture.date(29, 9))

        let fortnightly = try request(.weekly(calendar: calendar, interval: 2))
        #expect(fortnightly.repeatRule == .everyNDays)
        #expect(fortnightly.repeatEvery == 14)
        #expect(fortnightly.startAt == nil)
    }

    @Test func aTimeInTheRuleStartsTheNagWhenItHasNoStart() throws {
        let daily = try request(.daily(calendar: calendar, hours: [8]))
        #expect(daily.repeatRule == .daily)
        #expect(daily.startAt == Fixture.date(29, 8))

        let explicit = try request(.daily(calendar: calendar, hours: [8]), startAt: Fixture.date(28, 18))
        #expect(explicit.startAt == Fixture.date(28, 18))
    }

    @Test func particularDaysBecomeCustomTimes() throws {
        let rule = Calendar.RecurrenceRule.weekly(calendar: calendar, weekdays: [.every(.monday), .every(.thursday)], hours: [9])
        var state = NagState()

        let request = try request(rule)
        let task = try state.apply(request, now: now, calendar: calendar).task

        #expect(request.repeatRule == .custom)
        #expect(schedule(request.times) == [Slot(minute: 9 * 60, weekdays: [2, 5])])
        #expect(task.startAt == Fixture.date(29, 9))
    }

    @Test func particularDaysWithoutATimeUseTheStartsTime() throws {
        let rule = Calendar.RecurrenceRule.weekly(calendar: calendar, weekdays: [.every(.saturday)])
        let request = try request(rule, startAt: Fixture.date(28, 18, 30))
        #expect(request.repeatRule == .custom)
        #expect(schedule(request.times) == [Slot(minute: 18 * 60 + 30, weekdays: [7])])
    }

    @Test func severalTimesADayBecomeCustomTimes() throws {
        let request = try request(.daily(calendar: calendar, hours: [21, 9]))
        #expect(request.repeatRule == .custom)
        #expect(schedule(request.times) == [Slot(minute: 9 * 60, weekdays: Set(1...7)), Slot(minute: 21 * 60, weekdays: Set(1...7))])
        #expect(request.startAt == Fixture.date(28, 21))
    }

    @Test func monthlyRulesUseTheirDayOrTheStartsDay() throws {
        let onThe15th = try request(.monthly(calendar: calendar, daysOfTheMonth: [15]))
        #expect(onThe15th.repeatRule == .monthly)
        #expect(onThe15th.monthDay == 15)
        #expect(onThe15th.startAt == Fixture.date(15, 9, month: 11))

        let onThe15thAt8 = try request(.monthly(calendar: calendar, daysOfTheMonth: [15], hours: [20]))
        #expect(onThe15thAt8.startAt == Fixture.date(15, 20, month: 11))

        let monthly = try request(.monthly(calendar: calendar))
        #expect(monthly.monthDay == 28)
        #expect(monthly.startAt == nil)
    }

    @Test func rulesNagCantFollowAreRefused() {
        let refused: [Calendar.RecurrenceRule] = [
            .yearly(calendar: calendar),
            .hourly(calendar: calendar),
            .monthly(calendar: calendar, interval: 2),
            .monthly(calendar: calendar, daysOfTheMonth: [1, 15]),
            .monthly(calendar: calendar, weekdays: [.nth(1, .monday)]),
            .weekly(calendar: calendar, interval: 2, weekdays: [.every(.monday)]),
            .daily(calendar: calendar, months: [1]),
        ]
        for rule in refused {
            #expect(throws: NagRequestError.unsupportedRepeat) { try request(rule) }
        }
    }

    @Test func nagsRepeatsRoundTripThroughRecurrenceRules() throws {
        let tasks = [
            NagTask(title: "Daily", startAt: now, repeatRule: .daily, now: now),
            NagTask(title: "Weekdays", startAt: now, repeatRule: .weekdays, now: now),
            NagTask(title: "Weekly", startAt: now, repeatRule: .weekly, now: now),
            NagTask(title: "Every 3 days", startAt: now, repeatRule: .everyNDays, repeatEvery: 3, now: now),
            NagTask(title: "Monthly", startAt: now, repeatRule: .monthly, monthDay: 12, now: now),
        ]
        for task in tasks {
            let rule = try #require(task.recurrenceRule(calendar: calendar))
            let request = try request(rule, startAt: task.startAt)
            #expect(request.repeatRule == task.repeatRule, "\(task.title)")
            if task.repeatRule == .everyNDays { #expect(request.repeatEvery == task.repeatEvery) }
            if task.repeatRule == .monthly { #expect(request.monthDay == task.monthDay) }
        }
    }

    @Test func recurrenceRulesForOneOffsAndCustomTimes() {
        #expect(NagTask(title: "Once", startAt: now, now: now).recurrenceRule(calendar: calendar) == nil)

        let single = NagTask(title: "Mon", startAt: now, repeatRule: .custom, times: [NagTime(minute: 570, weekdays: [2])], now: now)
        #expect(single.recurrenceRule(calendar: calendar) == .weekly(calendar: calendar, weekdays: [.every(.monday)], hours: [9], minutes: [30]))

        let several = NagTask(
            title: "Twice",
            startAt: now,
            repeatRule: .custom,
            times: [NagTime(minute: 540, weekdays: [2]), NagTime(minute: 1260, weekdays: [3])],
            now: now
        )
        #expect(several.recurrenceRule(calendar: calendar) == nil)
    }
}
