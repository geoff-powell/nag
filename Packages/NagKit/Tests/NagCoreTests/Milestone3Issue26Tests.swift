import Foundation
import Testing
@testable import NagCore

@Suite struct Milestone3Issue26Tests {
    let calendar = Fixture.calendar
    /// Wednesday 28 October 2026, 12:00 UTC.
    let now = Fixture.date(28, 12)

    // MARK: - First step

    @Test func firstStepIsTrimmedUnquotedAndOneLine() {
        #expect(AssistantOutput.firstStep("  “Put your shoes by the door.”  \nThen go.", title: "Run") == "Put your shoes by the door.")
        #expect(AssistantOutput.firstStep("- Open the laptop", title: "Write report") == "Open the laptop")
    }

    @Test func firstStepRejectsEmptyAndTitleEcho() {
        #expect(AssistantOutput.firstStep("   \n ", title: "Run") == nil)
        #expect(AssistantOutput.firstStep("\"Call the dentist!\"", title: "Call the dentist") == nil)
    }

    @Test func firstStepIsCutAtAWordBoundary() {
        let long = Array(repeating: "word", count: 60).joined(separator: " ")
        let step = AssistantOutput.firstStep(long, title: "Task")
        #expect(step != nil)
        #expect(step!.count <= AssistantOutput.maxFirstStepLength)
        #expect(step!.hasSuffix("word"))
    }

    // MARK: - Steps

    @Test func stepsDropBlanksRepeatsAndListMarkers() {
        let steps = AssistantOutput.steps([
            SuggestedStep(title: "1. Fill the sink", estimateMinutes: 2),
            SuggestedStep(title: "   ", estimateMinutes: 5),
            SuggestedStep(title: "fill the sink!", estimateMinutes: 3),
            SuggestedStep(title: "Step 2: Wash the plates", estimateMinutes: 10),
            SuggestedStep(title: "• Dry up", estimateMinutes: nil),
        ])
        #expect(steps.map(\.title) == ["Fill the sink", "Wash the plates", "Dry up"])
        #expect(steps.map(\.estimateMinutes) == [2, 10, nil])
    }

    @Test func stepsAreCappedAtTwelve() {
        let raw = (1...20).map { SuggestedStep(title: "Step number \($0) thing", estimateMinutes: 1) }
        let steps = AssistantOutput.steps(raw)
        #expect(steps.count == 12)
        #expect(steps.last?.title == "Step number 12 thing")
    }

    @Test func estimatesOutsideOneToOneEightyAreDropped() {
        let steps = AssistantOutput.steps([
            SuggestedStep(title: "A", estimateMinutes: 0),
            SuggestedStep(title: "B", estimateMinutes: -4),
            SuggestedStep(title: "C", estimateMinutes: 181),
            SuggestedStep(title: "D", estimateMinutes: 180),
            SuggestedStep(title: "E", estimateMinutes: 1),
        ])
        #expect(steps.map(\.estimateMinutes) == [nil, nil, nil, 180, 1])
    }

    @Test func longStepTitlesAreShortened() {
        let steps = AssistantOutput.steps([SuggestedStep(title: String(repeating: "tidy ", count: 40))])
        #expect(steps.count == 1)
        #expect(steps[0].title.count <= AssistantOutput.maxStepLength)
    }

    // MARK: - Wording

    @Test func wordingDropsBadLines() {
        let lines = AssistantOutput.wording([
            "Time to water the plants.",
            "time to water the plants",
            "",
            "Water plants",
            "See https://example.com",
            String(repeating: "a", count: 121),
            "\"Your plants are thirsty.\"",
        ], title: "Water plants")
        #expect(lines == ["Time to water the plants.", "Your plants are thirsty."])
    }

    @Test func wordingIsCappedAtEightLines() {
        let lines = AssistantOutput.wording((1...12).map { "Line number \($0)." }, title: "T")
        #expect(lines.count == AssistantOutput.maxWordingLines)
    }

    // MARK: - Quick add

    private func resolve(_ fields: QuickAddFields) throws -> NagRequest {
        try fields.request(now: now, calendar: calendar)
    }

    @Test func weekdayAndTimeResolveToTheNextOne() throws {
        // "dentist thu 3pm" on a Wednesday.
        let request = try resolve(QuickAddFields(title: "Dentist", weekday: 5, hour: 15))
        #expect(request.title == "Dentist")
        #expect(request.startAt == Fixture.date(29, 15))
        #expect(request.repeatRule == .never)
    }

    @Test func todaysWeekdayIsTodayWhileTheTimeIsAhead() throws {
        let later = try resolve(QuickAddFields(title: "Gym", weekday: 4, hour: 18, minute: 30))
        #expect(later.startAt == Fixture.date(28, 18, 30))
        let earlier = try resolve(QuickAddFields(title: "Gym", weekday: 4, hour: 9))
        #expect(earlier.startAt == Fixture.date(4, 9, month: 11))
        let untimed = try resolve(QuickAddFields(title: "Gym", weekday: 4))
        #expect(untimed.startAt == nil)
    }

    @Test func weekdayWithoutTimeIsNineAM() throws {
        let request = try resolve(QuickAddFields(title: "Bins", weekday: 2))
        #expect(request.startAt == Fixture.date(2, 9, month: 11))
    }

    @Test func timeAloneIsTheNextTimeItComesRound() throws {
        #expect(try resolve(QuickAddFields(title: "Call", hour: 17)).startAt == Fixture.date(28, 17))
        #expect(try resolve(QuickAddFields(title: "Call", hour: 8, minute: 15)).startAt == Fixture.date(29, 8, 15))
    }

    @Test func tomorrowAndToday() throws {
        #expect(try resolve(QuickAddFields(title: "Pay rent", daysFromToday: 1)).startAt == Fixture.date(29, 9))
        #expect(try resolve(QuickAddFields(title: "Pay rent", daysFromToday: 0, hour: 20)).startAt == Fixture.date(28, 20))
        #expect(try resolve(QuickAddFields(title: "Pay rent", daysFromToday: 0)).startAt == nil)
    }

    @Test func todayAtATimeThatHasGoneIsRejected() {
        #expect(throws: QuickAddError.inThePast) {
            try resolve(QuickAddFields(title: "Lunch", daysFromToday: 0, hour: 11))
        }
    }

    @Test func datesThatHavePassedMoveToNextYear() throws {
        #expect(try resolve(QuickAddFields(title: "Taxes", month: 1, day: 31)).startAt
            == calendar.date(from: DateComponents(year: 2027, month: 1, day: 31, hour: 9)))
        #expect(try resolve(QuickAddFields(title: "Party", month: 12, day: 24, hour: 19)).startAt
            == Fixture.date(24, 19, month: 12))
    }

    @Test func dayWithoutMonthIsTheNextOne() throws {
        #expect(try resolve(QuickAddFields(title: "Rent", day: 1)).startAt == Fixture.date(1, 9, month: 11))
        #expect(try resolve(QuickAddFields(title: "Rent", day: 30, hour: 10)).startAt == Fixture.date(30, 10))
    }

    @Test func impossibleDatesAndTimesAreRejected() {
        #expect(throws: QuickAddError.invalidDate) { try resolve(QuickAddFields(title: "X", month: 2, day: 30)) }
        #expect(throws: QuickAddError.invalidDate) { try resolve(QuickAddFields(title: "X", hour: 24)) }
        #expect(throws: QuickAddError.invalidDate) { try resolve(QuickAddFields(title: "X", hour: 9, minute: 75)) }
        #expect(throws: QuickAddError.invalidDate) { try resolve(QuickAddFields(title: "X", minute: 30)) }
        #expect(throws: QuickAddError.invalidDate) { try resolve(QuickAddFields(title: "X", weekday: 9)) }
        #expect(throws: QuickAddError.invalidDate) { try resolve(QuickAddFields(title: "X", month: 13, day: 1)) }
    }

    @Test func leapDayFindsTheNextLeapYear() throws {
        #expect(try resolve(QuickAddFields(title: "Leap", month: 2, day: 29)).startAt
            == calendar.date(from: DateComponents(year: 2028, month: 2, day: 29, hour: 9)))
    }

    @Test func blankTitleIsRejected() {
        #expect(throws: QuickAddError.missingTitle) { try resolve(QuickAddFields(title: "  \n", hour: 15)) }
    }

    @Test func repeatsMapOnlyToSupportedRules() throws {
        #expect(try resolve(QuickAddFields(title: "A", repeatKind: "daily")).repeatRule == .daily)
        #expect(try resolve(QuickAddFields(title: "A", repeatKind: "Weekdays")).repeatRule == .weekdays)
        #expect(try resolve(QuickAddFields(title: "A", weekday: 3, repeatKind: "weekly")).repeatRule == .weekly)
        let monthly = try resolve(QuickAddFields(title: "A", day: 15, repeatKind: "monthly"))
        #expect(monthly.repeatRule == .monthly)
        #expect(monthly.monthDay == 15)
        let everyFew = try resolve(QuickAddFields(title: "A", repeatKind: "everyNDays", repeatEvery: 3))
        #expect(everyFew.repeatRule == .everyNDays)
        #expect(everyFew.repeatEvery == 3)
        #expect(try resolve(QuickAddFields(title: "A", repeatKind: "everyNDays", repeatEvery: 1)).repeatRule == .daily)
        #expect(try resolve(QuickAddFields(title: "A", repeatKind: "everyNDays", repeatEvery: 900)).repeatRule == .never)
        #expect(try resolve(QuickAddFields(title: "A", repeatKind: "custom")).repeatRule == .never)
        #expect(try resolve(QuickAddFields(title: "A", repeatKind: "yearly")).repeatRule == .never)
        #expect(try resolve(QuickAddFields(title: "A")).repeatRule == .never)
    }

    @Test func weekdayNamesParse() {
        #expect(QuickAddFields.weekday(named: "Thursday") == 5)
        #expect(QuickAddFields.weekday(named: "sun") == 1)
        #expect(QuickAddFields.weekday(named: "SAT") == 7)
        #expect(QuickAddFields.weekday(named: "someday") == nil)
    }

    @Test func quickAddMakesANewDraftAndSavesNothing() throws {
        let state = NagState()
        let request = try resolve(QuickAddFields(title: "Dentist", weekday: 5, hour: 15))
        let draft = try state.draft(for: request, now: now, calendar: calendar)
        #expect(draft.isNew)
        #expect(draft.task.title == "Dentist")
        #expect(draft.task.startAt == Fixture.date(29, 15))
        #expect(draft.task.proof == .none)
        #expect(state.tasks.isEmpty)
    }

    @Test func unusableReadingsFallBackToTheTypedText() {
        let typed = "lunch with Sam today 11am"
        let past = QuickAddFields.request(
            for: typed,
            fields: QuickAddFields(title: "Lunch with Sam", daysFromToday: 0, hour: 11),
            now: now,
            calendar: calendar
        )
        #expect(past == NagRequest(title: typed))
        #expect(QuickAddFields.request(for: "  dentist thu 3pm ", fields: nil, now: now, calendar: calendar)
            == NagRequest(title: "dentist thu 3pm"))
        let read = QuickAddFields.request(
            for: "dentist thu 3pm",
            fields: QuickAddFields(title: "Dentist", weekday: 5, hour: 15),
            now: now,
            calendar: calendar
        )
        #expect(read.title == "Dentist")
        #expect(read.startAt == Fixture.date(29, 15))
    }

    @Test func weeklyOnAWeekdayKeepsThatWeekday() throws {
        var state = NagState()
        let request = try resolve(QuickAddFields(title: "Bins", weekday: 3, hour: 19, repeatKind: "weekly"))
        let draft = try state.apply(request, now: now, calendar: calendar)
        #expect(draft.task.repeatRule == .weekly)
        #expect(calendar.component(.weekday, from: draft.task.startAt) == 3)
        #expect(draft.task.startAt == Fixture.date(3, 19, month: 11))
    }

    // MARK: - Wording pools

    private func dueTask(_ title: String = "Water plants", tone: NagTone? = nil) -> NagTask {
        var task = NagTask(title: title, startAt: Fixture.date(28, 13), now: Fixture.date(28, 7))
        task.style.escalation = .steady
        task.style.intervalMinutes = 10
        task.style.tone = tone
        return task
    }

    @Test func setWordingChecksLinesAndRecordsTitleAndTone() {
        let task = dueTask()
        var state = NagState(tasks: [task])
        #expect(state.needsWording(task))
        state.setWording(["One.", "one", "", "Two."], for: task.id, tone: .standard, now: now)
        #expect(state.wording[task.id.uuidString]?.lines == ["One.", "Two."])
        #expect(!state.needsWording(task))
    }

    @Test func wordingGoesStaleWhenTitleOrToneChanges() {
        var task = dueTask()
        var state = NagState(tasks: [task])
        state.setWording(["One.", "Two."], for: task.id, tone: .standard, now: now)
        task.title = "Water the garden"
        state.tasks[0] = task
        #expect(state.needsWording(task))
        task.title = "Water plants"
        task.style.tone = .pushy
        state.tasks[0] = task
        #expect(state.needsWording(task))
    }

    @Test func emptyWordingIsNotStored() {
        let task = dueTask()
        var state = NagState(tasks: [task])
        state.setWording(["", "Water plants"], for: task.id, tone: .standard, now: now)
        #expect(state.wording.isEmpty)
    }

    @Test func deletingANagDropsItsWording() {
        let task = dueTask()
        var state = NagState(tasks: [task])
        state.setWording(["One."], for: task.id, tone: .standard, now: now)
        state.deleteTask(task.id, at: now)
        #expect(state.wording.isEmpty)
    }

    @Test func plannerUsesThePoolOnEveryOtherNagFromTheThird() {
        let task = dueTask()
        var state = NagState(tasks: [task])
        state.setWording(["Pool A.", "Pool B."], for: task.id, tone: .standard, now: now)
        let planner = NagPlanner(calendar: calendar)
        let plan = planner.plan(tasks: state.tasks, quietHours: QuietHours(), tone: .standard, wording: state.wording, now: now)
        let bodies = plan.notifications.prefix(7).map(\.body)
        let plain = planner.plan(tasks: state.tasks, quietHours: QuietHours(), tone: .standard, now: now)
            .notifications.prefix(7).map(\.body)
        #expect(bodies[0] == plain[0])
        #expect(bodies[1] == plain[1])
        #expect(bodies[2] == "Pool A.")
        #expect(bodies[3] == plain[3])
        #expect(bodies[4] == "Pool B.")
        #expect(bodies[6] == "Pool A.")
    }

    @Test func plannerIsDeterministicWithAPool() {
        let task = dueTask()
        var state = NagState(tasks: [task])
        state.setWording(["Pool A.", "Pool B.", "Pool C."], for: task.id, tone: .standard, now: now)
        let planner = NagPlanner(calendar: calendar)
        let first = planner.plan(tasks: state.tasks, quietHours: QuietHours(), wording: state.wording, now: now)
        let second = planner.plan(tasks: state.tasks, quietHours: QuietHours(), wording: state.wording, now: now)
        #expect(first == second)
    }

    @Test func stalePoolFallsBackToBuiltInWording() {
        let task = dueTask(tone: .pushy)
        var state = NagState(tasks: [task])
        state.setWording(["Pool A."], for: task.id, tone: .gentle, now: now)
        let planner = NagPlanner(calendar: calendar)
        let pooled = planner.plan(tasks: state.tasks, quietHours: QuietHours(), wording: state.wording, now: now)
        let plain = planner.plan(tasks: state.tasks, quietHours: QuietHours(), now: now)
        #expect(pooled == plain)
    }

    @Test func repeatingNotificationsUseThePoolOnTiersZeroAndTwo() {
        var task = dueTask()
        task.startAt = Fixture.date(28, 11, 55)
        var state = NagState(tasks: [task])
        state.setWording(["Pool A.", "Pool B."], for: task.id, tone: .standard, now: now)
        let planner = NagPlanner(calendar: calendar)
        let tierZero = planner.plan(tasks: state.tasks, quietHours: QuietHours(), wording: state.wording, now: now)
        #expect(tierZero.notifications.first?.body == "Pool A.")
        let tierOne = planner.plan(tasks: state.tasks, quietHours: QuietHours(), wording: state.wording, now: Fixture.date(28, 12, 30))
        #expect(tierOne.notifications.first?.body == NagMessages.repeatingBody(title: task.title, tier: 1))
        let tierTwo = planner.plan(tasks: state.tasks, quietHours: QuietHours(), wording: state.wording, now: Fixture.date(28, 13, 30))
        #expect(tierTwo.notifications.first?.body == "Pool B.")
    }

    @Test func routineStepStillLeadsAPooledLine() {
        var task = dueTask()
        task.startAt = Fixture.date(28, 11, 55)
        task.steps = [RoutineStep(title: "Fill can")]
        var state = NagState(tasks: [task])
        state.setWording(["Pool A."], for: task.id, tone: .standard, now: now)
        let plan = NagPlanner(calendar: calendar).plan(tasks: state.tasks, quietHours: QuietHours(), wording: state.wording, now: now)
        #expect(plan.notifications.first?.body == "Step 1 of 1: Fill can\nPool A.")
    }

    // MARK: - Storage

    @Test func wordingAndSettingRoundTripAndOldStateStillLoads() throws {
        let task = dueTask()
        var state = NagState(tasks: [task])
        state.settings.useAppleIntelligence = true
        state.setWording(["One."], for: task.id, tone: .standard, now: now)
        let decoded = try JSONDecoder().decode(NagState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)

        let old = try JSONDecoder().decode(NagState.self, from: Data(#"{"tasks":[],"settings":{}}"#.utf8))
        #expect(old.wording.isEmpty)
        #expect(!old.settings.useAppleIntelligence)
    }

    @Test func wordingIsNotPartOfTheSyncedNag() throws {
        let task = dueTask()
        var state = NagState(tasks: [task])
        state.setWording(["One."], for: task.id, tone: .standard, now: now)
        let json = String(decoding: try JSONEncoder().encode(state.tasks[0]), as: UTF8.self)
        #expect(!json.contains("One."))
    }
}
