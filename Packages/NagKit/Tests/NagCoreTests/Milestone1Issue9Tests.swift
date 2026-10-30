import Foundation
import Testing
@testable import NagCore

@Suite struct Milestone1Issue9SnoozeLimitTests {
    @Test func refusedExplicitSnoozeDoesNotMutateTask() {
        let now = Fixture.date(28, 9)
        var task = NagTask(
            title: "Laundry",
            startAt: Fixture.date(28, 8),
            style: NagStyle(maxSnoozes: 1),
            now: Fixture.date(28, 8)
        )
        let first = task.snooze(at: now, minutes: 5)
        #expect(first)
        let exhausted = task

        let refused = task.snooze(at: Fixture.date(28, 9, 1), minutes: 60)
        #expect(!refused)
        #expect(task == exhausted)
    }

    @Test func unlimitedExplicitSnoozesKeepConsumingCount() {
        let now = Fixture.date(28, 9)
        var task = NagTask(
            title: "Laundry",
            startAt: Fixture.date(28, 8),
            style: NagStyle(maxSnoozes: nil),
            now: Fixture.date(28, 8)
        )

        for minute in [5, 15, 60, 5] {
            let snoozed = task.snooze(at: now, minutes: minute)
            #expect(snoozed)
        }

        #expect(task.snoozeCount == 4)
        #expect(task.snoozesLeft == nil)
    }

    @Test func optionLabelsMatchTheirDurations() {
        #expect(SnoozeOption.allCases.map(\.label) == ["5 min", "15 min", "1 hr"])
        #expect(SnoozeOption.allCases.map(\.minutes) == [5, 15, 60])
    }
}
