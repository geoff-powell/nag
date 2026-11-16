import Foundation
import Testing
@testable import NagCore

@Suite struct Milestone3Issue22Tests {
    let calendar = Fixture.calendar

    private func daily(_ title: String = "Meds", hour: Int = 8) -> NagTask {
        NagTask(title: title, startAt: Fixture.date(26, hour), repeatRule: .daily, now: Fixture.date(25, 7))
    }

    private func record(
        _ nag: UUID = UUID(),
        _ title: String = "Meds",
        due: Date,
        done: Date,
        started: Date? = nil,
        snoozes: Int = 0,
        keyScanned: Bool = false
    ) -> CompletionRecord {
        CompletionRecord(nagID: nag, title: title, scheduledAt: due, completedAt: done, startedAt: started, snoozes: snoozes, keyScanned: keyScanned)
    }

    // MARK: - Recording

    @Test func completingLogsTheOccurrenceBeforeItResets() throws {
        var task = daily()
        _ = task.snooze(at: Fixture.date(26, 8, 5))
        _ = task.snooze(at: Fixture.date(26, 8, 20))
        task.snoozedUntil = nil
        task.start(at: Fixture.date(26, 8, 40))
        let before = NagState(tasks: [task])
        var after = before
        after.tasks[0].complete(at: Fixture.date(26, 9), calendar: calendar)

        let changes = CompletionHistory.changes(from: before, to: after)
        guard case .completed(let logged) = try #require(changes.first) else {
            Issue.record("Expected a completion")
            return
        }
        #expect(changes.count == 1)
        #expect(logged.nagID == task.id)
        #expect(logged.title == "Meds")
        #expect(logged.scheduledAt == Fixture.date(26, 8))
        #expect(logged.completedAt == Fixture.date(26, 9))
        #expect(logged.startedAt == Fixture.date(26, 8, 40))
        #expect(logged.snoozes == 2)
        #expect(!logged.keyScanned)
        #expect(logged.startDelay == 40 * 60)
        // The nag itself has moved on.
        #expect(after.tasks[0].snoozeCount == 0)
    }

    @Test func aScannedKeyIsRecorded() throws {
        let key = UnlockKey(name: "Bottle", kind: .nfc, fingerprint: "f")
        var task = daily()
        task.proof = .scanKey(key.id)
        let before = NagState(tasks: [task], keys: [key])
        var after = before
        after.tasks[0].complete(at: Fixture.date(26, 9), calendar: calendar, keyScanned: true)
        guard case .completed(let logged) = CompletionHistory.changes(from: before, to: after).first else {
            Issue.record("Expected a completion")
            return
        }
        #expect(logged.keyScanned)
    }

    @Test func keyScannedSurvivesEncoding() throws {
        var task = daily()
        task.complete(at: Fixture.date(26, 9), calendar: calendar, keyScanned: true)
        let decoded = try JSONDecoder().decode(NagTask.self, from: JSONEncoder().encode(task))
        #expect(decoded.completionUndo?.keyScanned == true)
    }

    @Test func undoSnapshotsFromOlderBuildsDecodeAsNotScanned() throws {
        let json = #"{"startAt":0,"snoozeCount":1,"completedAtMoment":60}"#
        let undo = try JSONDecoder().decode(CompletionUndo.self, from: Data(json.utf8))
        #expect(!undo.keyScanned)
    }

    @Test func editsThatDontCompleteLogNothing() {
        var task = daily()
        task.complete(at: Fixture.date(26, 9), calendar: calendar)
        let before = NagState(tasks: [task])
        var after = before
        after.tasks[0].title = "Renamed"
        _ = after.tasks[0].snooze(at: Fixture.date(27, 8, 5))
        #expect(CompletionHistory.changes(from: before, to: after).isEmpty)
    }

    @Test func undoingRemovesTheRecord() {
        var task = daily()
        let start = NagState(tasks: [task])
        task.complete(at: Fixture.date(26, 9), calendar: calendar)
        let completed = NagState(tasks: [task])
        var history = CompletionHistory()
        history.apply(CompletionHistory.changes(from: start, to: completed))
        #expect(history.records.count == 1)

        task.undoCompletion(at: Fixture.date(26, 9, 2))
        let undone = NagState(tasks: [task])
        let changes = CompletionHistory.changes(from: completed, to: undone)
        #expect(changes == [.undone(nagID: task.id, completedAt: Fixture.date(26, 9))])
        history.apply(changes)
        #expect(history.records.isEmpty)
    }

    @Test func aStartFromAnEarlierOccurrenceIsIgnored() {
        var task = daily()
        task.startedAt = Fixture.date(25, 8, 30)
        let before = NagState(tasks: [task])
        var after = before
        after.tasks[0].complete(at: Fixture.date(26, 9), calendar: calendar)
        guard case .completed(let logged) = CompletionHistory.changes(from: before, to: after).first else {
            Issue.record("Expected a completion")
            return
        }
        #expect(logged.startedAt == nil)
        #expect(logged.startDelay == 3600)
    }

    @Test func theSameCompletionSeenTwiceIsKeptOnce() {
        let id = UUID()
        var history = CompletionHistory()
        history.record(record(id, due: Fixture.date(26, 8), done: Fixture.date(26, 9)))
        history.record(record(id, due: Fixture.date(26, 8), done: Fixture.date(26, 9)))
        history.record(record(id, due: Fixture.date(25, 8), done: Fixture.date(25, 9)))
        #expect(history.records.map(\.completedAt) == [Fixture.date(25, 9), Fixture.date(26, 9)])
    }

    @Test func earlyCompletionCountsAsOnTime() {
        #expect(record(due: Fixture.date(26, 9), done: Fixture.date(26, 8)).startDelay == 0)
    }

    @Test func completionsFromEveryProcessAreLoggedByTheStore() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(directory: directory)
        let task = NagTask(title: "Meds", startAt: Date().addingTimeInterval(-600), repeatRule: .daily)
        store.update { $0.tasks = [task] }
        #expect(store.loadHistory().isEmpty)

        // NagActions is what widgets, Siri and notifications use.
        try NagActions.complete(taskID: task.id, store: store)
        let logged = store.loadHistory().records
        #expect(logged.map(\.nagID) == [task.id])
        #expect(SharedStore(directory: directory).loadHistory() == store.loadHistory())

        store.update { _ = $0.tasks[0].undoCompletion(at: Date()) }
        #expect(store.loadHistory().records.isEmpty)
        // The history lives in its own file, not in the nag store.
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "history.json").path))
    }

    // MARK: - Pruning

    @Test func oldRecordsRollUpIntoWeeklyTotals() {
        let id = UUID()
        var history = CompletionHistory()
        // 2026-10-28 is a Wednesday; with the default Sunday-first calendar its week starts on the 25th.
        let now = Fixture.date(28, 12)
        let old = Fixture.date(28, 9, month: 7) // A Tuesday, well before the detailed weeks.
        history.record(record(id, "Old name", due: old.addingTimeInterval(-1800), done: old, snoozes: 1))
        history.record(record(id, "New name", due: old.addingTimeInterval(86_400 - 600), done: old.addingTimeInterval(86_400), keyScanned: true))
        history.record(record(id, due: Fixture.date(27, 8), done: Fixture.date(27, 9)))

        history.prune(now: now, calendar: calendar)
        #expect(history.records.map(\.completedAt) == [Fixture.date(27, 9)])
        #expect(history.rollups.count == 1)
        let rollup = history.rollups[0]
        #expect(rollup.count == 2)
        #expect(rollup.title == "New name")
        #expect(rollup.totalStartDelay == 2400)
        #expect(rollup.snoozes == 1)
        #expect(rollup.keyScans == 1)
        #expect(rollup.weekStart == Fixture.date(26, 0, month: 7))
    }

    @Test func detailIsKeptForTheRecentWeeks() {
        var history = CompletionHistory()
        let now = Fixture.date(28, 12)
        // The first day of the oldest detailed week.
        let cutoff = calendar.date(byAdding: .weekOfYear, value: -(CompletionHistory.detailWeeks - 1), to: Fixture.date(25, 0))!
        history.record(record(due: cutoff, done: cutoff))
        history.record(record(due: cutoff, done: cutoff.addingTimeInterval(-1)))
        history.prune(now: now, calendar: calendar)
        #expect(history.records.map(\.completedAt) == [cutoff])
        #expect(history.rollups.count == 1)
    }

    @Test func recordsAndRollupsAreCapped() {
        let now = Fixture.date(28, 12)
        var history = CompletionHistory()
        let extra = 5
        for index in 0..<(CompletionHistory.maxRecords + extra) {
            let done = now.addingTimeInterval(-Double(index) * 60)
            history.record(record(due: done, done: done))
        }
        history.prune(now: now, calendar: calendar)
        #expect(history.records.count == CompletionHistory.maxRecords)
        #expect(history.rollups.reduce(0) { $0 + $1.count } == extra)

        history.rollups = (0..<(CompletionHistory.maxRollups + 3)).map { index in
            CompletionRollup(nagID: UUID(), title: "\(index)", weekStart: Fixture.date(1, 0, month: 1).addingTimeInterval(Double(index)), count: 1)
        }
        history.prune(now: now, calendar: calendar)
        #expect(history.rollups.count == CompletionHistory.maxRollups)
        #expect(history.rollups.first?.title == "3")
    }

    // MARK: - Weekly review

    @Test func reviewsWhatGotDoneThisWeek() {
        let meds = daily()
        let walk = daily("Walk", hour: 18)
        let history = CompletionHistory(records: [
            record(meds.id, due: Fixture.date(24, 8), done: Fixture.date(24, 8, 5)), // Saturday: last week
            record(meds.id, due: Fixture.date(26, 8), done: Fixture.date(26, 8, 10)),
            record(meds.id, due: Fixture.date(27, 8), done: Fixture.date(27, 8, 50), started: Fixture.date(27, 8, 30), snoozes: 2),
            record(walk.id, "Walk", due: Fixture.date(27, 18), done: Fixture.date(27, 17)),
        ])
        let review = WeeklyReview.make(history: history, tasks: [meds, walk], week: Fixture.date(28, 12), now: Fixture.date(28, 12), calendar: calendar)
        #expect(review.week.start == Fixture.date(25, 0))
        #expect(review.week.end == Fixture.date(1, 0, month: 11))
        #expect(review.doneCount == 3)
        #expect(review.averageStartDelay == TimeInterval(40 * 60) / 3)
        #expect(review.entries.map(\.title) == ["Meds", "Walk"])
        #expect(review.entries[0].averageStartDelay == 20 * 60)
        #expect(review.entries[0].snoozes == 2)
        #expect(review.slipping.map(\.title) == ["Meds"])
        #expect(review.suggestion == nil)
    }

    @Test func anEmptyWeekHasNoAverage() {
        let review = WeeklyReview.make(history: CompletionHistory(), tasks: [], week: Fixture.date(28, 12), now: Fixture.date(28, 12), calendar: calendar)
        #expect(review.isEmpty)
        #expect(review.averageStartDelay == nil)
        #expect(review.streak == ProgressStreak(weeks: 0, status: .notStarted))
    }

    @Test func olderWeeksAreReviewedFromRollups() {
        let id = UUID()
        let history = CompletionHistory(rollups: [
            CompletionRollup(nagID: id, title: "Meds", weekStart: Fixture.date(26, 0, month: 7), count: 4, totalStartDelay: 4 * 1200),
        ])
        let review = WeeklyReview.make(history: history, tasks: [], week: Fixture.date(29, 12, month: 7), now: Fixture.date(28, 12), calendar: calendar)
        #expect(review.doneCount == 4)
        #expect(review.averageStartDelay == 1200)
        #expect(review.slipping.map(\.id) == [id])
    }

    @Test func weeksFollowTheCalendarsFirstWeekday() {
        var monday = calendar
        monday.firstWeekday = 2
        let history = CompletionHistory(records: [record(due: Fixture.date(25, 9), done: Fixture.date(25, 9))]) // Sunday
        let sundayFirst = WeeklyReview.make(history: history, tasks: [], week: Fixture.date(28, 12), now: Fixture.date(28, 12), calendar: calendar)
        let mondayFirst = WeeklyReview.make(history: history, tasks: [], week: Fixture.date(28, 12), now: Fixture.date(28, 12), calendar: monday)
        #expect(sundayFirst.doneCount == 1)
        #expect(mondayFirst.doneCount == 0)
        #expect(mondayFirst.week.start == Fixture.date(26, 0))
    }

    @Test func weekBoundariesSurviveDaylightSavingChanges() {
        // The UK clocks go back at 2am on Sunday 25 October 2026, so that week is 169 hours long.
        let calendar = DSTFixture.calendar
        let lastMinute = DSTFixture.date(10, 31, 23).addingTimeInterval(59 * 60)
        let history = CompletionHistory(records: [
            record(due: DSTFixture.date(10, 25, 0), done: DSTFixture.date(10, 25, 0)),
            record(due: lastMinute, done: lastMinute),
            record(due: DSTFixture.date(11, 1, 0), done: DSTFixture.date(11, 1, 0)),
        ])
        let review = WeeklyReview.make(history: history, tasks: [], week: DSTFixture.date(10, 28, 12), now: DSTFixture.date(10, 28, 12), calendar: calendar)
        #expect(review.week.duration == 169 * 3600)
        #expect(review.doneCount == 2)
    }

    @Test func rollupsStayInTheirWeekAfterATimeZoneChange() {
        var tokyo = calendar
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var losAngeles = calendar
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        var history = CompletionHistory(records: [record(due: Fixture.date(6, 3, month: 7), done: Fixture.date(6, 3, month: 7))])
        history.prune(now: Fixture.date(28, 12), calendar: tokyo)
        let weekStart = history.rollups[0].weekStart
        let review = WeeklyReview.make(history: history, tasks: [], week: weekStart.addingTimeInterval(3 * 86_400), now: Fixture.date(28, 12), calendar: losAngeles)
        #expect(review.doneCount == 1)
    }

    @Test func suggestsMovingANagThatUsuallyRunsLate() throws {
        let meds = daily()
        let records = [26, 27, 28].map { day in
            record(meds.id, due: Fixture.date(day, 8), done: Fixture.date(day, 8, 25), snoozes: 1)
        } + [record(meds.id, due: Fixture.date(19, 8), done: Fixture.date(19, 8, 40))]
        let review = WeeklyReview.make(history: CompletionHistory(records: records.sorted { $0.completedAt < $1.completedAt }),
                                       tasks: [meds], week: Fixture.date(28, 12), now: Fixture.date(28, 12), calendar: calendar)
        let suggestion = try #require(review.suggestion)
        #expect(suggestion.nagID == meds.id)
        #expect(suggestion.currentMinute == 8 * 60)
        #expect(suggestion.typicalDelay == 25 * 60)
        #expect(suggestion.suggestedMinute == 8 * 60 + 30)
        #expect(suggestion.samples == 4)
        let message = suggestion.message { String(format: "%d:%02d", $0 / 60, $0 % 60) }
        #expect(message == "“Meds” usually gets going about 25 min after 8:00. Moving it to 8:30 might suit your day better.")
    }

    @Test func noSuggestionWithoutEnoughConsistentLateness() {
        let meds = daily()
        let fewSamples = [26, 27].map { record(meds.id, due: Fixture.date($0, 8), done: Fixture.date($0, 9)) }
        let onTime = [25, 26, 27].map { record(meds.id, due: Fixture.date($0, 8), done: Fixture.date($0, 8, 5)) }
        let wayLate = [25, 26, 27].map { record(meds.id, due: Fixture.date($0, 8), done: Fixture.date($0, 14)) }
        for records in [fewSamples, onTime, wayLate] {
            let review = WeeklyReview.make(history: CompletionHistory(records: records), tasks: [meds], week: Fixture.date(28, 12), now: Fixture.date(28, 12), calendar: calendar)
            #expect(review.suggestion == nil)
        }
    }

    @Test func noSuggestionOnceTheTimeHasMovedOrTheNagIsGone() {
        var meds = daily()
        let records = [25, 26, 27].map { record(meds.id, due: Fixture.date($0, 8), done: Fixture.date($0, 8, 30)) }
        let history = CompletionHistory(records: records)
        #expect(WeeklyReview.make(history: history, tasks: [], week: Fixture.date(28, 12), now: Fixture.date(28, 12), calendar: calendar).suggestion == nil)
        meds.startAt = Fixture.date(29, 8, 30)
        #expect(WeeklyReview.make(history: history, tasks: [meds], week: Fixture.date(28, 12), now: Fixture.date(28, 12), calendar: calendar).suggestion == nil)
    }

    @Test func customNagsSuggestForTheTimeThatRunsLate() throws {
        let nag = NagTask(
            title: "Stretch",
            startAt: Fixture.date(26, 9),
            repeatRule: .custom,
            times: [NagTime(minute: 9 * 60), NagTime(minute: 21 * 60)],
            now: Fixture.date(25, 7)
        )
        let records = [25, 26, 27].map { record(nag.id, "Stretch", due: Fixture.date($0, 21), done: Fixture.date($0, 21, 50)) }
            + [record(nag.id, "Stretch", due: Fixture.date(26, 9), done: Fixture.date(26, 9))]
        let review = WeeklyReview.make(history: CompletionHistory(records: records.sorted { $0.completedAt < $1.completedAt }),
                                       tasks: [nag], week: Fixture.date(28, 12), now: Fixture.date(28, 12), calendar: calendar)
        let suggestion = try #require(review.suggestion)
        #expect(suggestion.currentMinute == 21 * 60)
        #expect(suggestion.suggestedMinute == 21 * 60 + 45)
    }

    @Test func earliestWeekCoversRecordsAndRollups() {
        let history = CompletionHistory(
            records: [record(due: Fixture.date(27, 8), done: Fixture.date(27, 8))],
            rollups: [CompletionRollup(nagID: UUID(), title: "Old", weekStart: Fixture.date(26, 0, month: 7), count: 1)]
        )
        #expect(WeeklyReview.earliestWeek(in: history, calendar: calendar) == Fixture.date(26, 0, month: 7))
        #expect(WeeklyReview.earliestWeek(in: CompletionHistory(), calendar: calendar) == nil)
    }

    // MARK: - Streak

    private func history(weeksAgo: [Int]) -> CompletionHistory {
        let records = weeksAgo.sorted(by: >).map { ago in
            let done = calendar.date(byAdding: .weekOfYear, value: -ago, to: Fixture.date(27, 9))!
            return record(due: done, done: done)
        }
        return CompletionHistory(records: records)
    }

    @Test func theStreakCountsWeeksWithSomethingDone() {
        let streak = ProgressStreak.make(history: history(weeksAgo: [0, 1, 2]), now: Fixture.date(28, 12), calendar: calendar)
        #expect(streak == ProgressStreak(weeks: 3, status: .active))
    }

    @Test func aQuietWeekPausesTheStreakInsteadOfResettingIt() {
        // Done three weeks ago and the week before, nothing for two weeks.
        let paused = ProgressStreak.make(history: history(weeksAgo: [2, 3]), now: Fixture.date(28, 12), calendar: calendar)
        #expect(paused == ProgressStreak(weeks: 2, status: .paused))
        // One thing done picks it back up where it left off.
        let resumed = ProgressStreak.make(history: history(weeksAgo: [0, 2, 3]), now: Fixture.date(28, 12), calendar: calendar)
        #expect(resumed == ProgressStreak(weeks: 3, status: .active))
    }

    @Test func theStreakStaysOpenUntilTheWeekIsOver() {
        let streak = ProgressStreak.make(history: history(weeksAgo: [1, 2]), now: Fixture.date(28, 12), calendar: calendar)
        #expect(streak == ProgressStreak(weeks: 2, status: .open))
    }

    @Test func theStreakCountsRolledUpWeeksAndIgnoresTheFuture() {
        var past = history(weeksAgo: [0, 20])
        past.prune(now: Fixture.date(28, 12), calendar: calendar)
        #expect(!past.rollups.isEmpty)
        past.record(record(due: Fixture.date(10, 9, month: 11), done: Fixture.date(10, 9, month: 11)))
        let streak = ProgressStreak.make(history: past, now: Fixture.date(28, 12), calendar: calendar)
        #expect(streak.weeks == 2)
    }
}

@Suite struct ReviewCopyTests {
    let calendar = Fixture.calendar

    @Test func delaysReadAsRoughTimes() {
        #expect(ReviewCopy.delay(20) == "right on time")
        #expect(ReviewCopy.delay(25 * 60) == "about 25 min")
        #expect(ReviewCopy.delay(60 * 60) == "about 1 hr")
        #expect(ReviewCopy.delay(95 * 60) == "about 1 hr 35 min")
    }

    @Test func streakCopyNeverMentionsWhatWasMissed() {
        #expect(ReviewCopy.streak(ProgressStreak(weeks: 0, status: .notStarted)) == nil)
        #expect(ReviewCopy.streak(ProgressStreak(weeks: 1, status: .active)) == "1 week with progress, this one included.")
        let paused = ReviewCopy.streak(ProgressStreak(weeks: 4, status: .paused)) ?? ""
        #expect(paused.hasPrefix("4 weeks with progress"))
        #expect(!paused.localizedCaseInsensitiveContains("miss"))
        #expect(!paused.localizedCaseInsensitiveContains("fail"))
    }

    @Test func weekTitlesAreRelativeWhenRecent() {
        let now = Fixture.date(28, 12)
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)!
        let lastWeek = calendar.dateInterval(of: .weekOfYear, for: Fixture.date(21, 12))!
        let older = calendar.dateInterval(of: .weekOfYear, for: Fixture.date(14, 12))!
        #expect(ReviewCopy.weekTitle(thisWeek, now: now, calendar: calendar) == "This week")
        #expect(ReviewCopy.weekTitle(lastWeek, now: now, calendar: calendar) == "Last week")
        #expect(ReviewCopy.weekTitle(older, now: now, calendar: calendar).contains("Oct"))
    }
}
