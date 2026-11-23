import Foundation
import Testing
@testable import NagCore

@Suite struct NagArchiveTests {
    @Test func archivedNagPersistsAndStopsSchedulingUntilRestored() throws {
        let now = Fixture.date(28, 9)
        let task = NagTask(title: "Daily", startAt: now, repeatRule: .daily, now: now)
        let planner = NagPlanner(calendar: Fixture.calendar)
        var state = NagState(tasks: [task])

        #expect(task.isOutstanding(at: now))
        #expect(!planner.plan(tasks: state.tasks, quietHours: QuietHours(), now: now).notifications.isEmpty)

        state.setTaskArchived(task.id, archived: true, at: now)
        state = try JSONDecoder().decode(NagState.self, from: JSONEncoder().encode(state))
        let archived = try #require(state.task(task.id))
        #expect(archived.isArchived)
        #expect(!archived.isOutstanding(at: now))
        #expect(!archived.canSnooze(at: now))
        #expect(!archived.canComplete(at: now, calendar: Fixture.calendar))
        #expect(planner.plan(tasks: state.tasks, quietHours: QuietHours(), now: now).notifications.isEmpty)
        #expect(WidgetSnapshot.make(from: state, now: now, calendar: Fixture.calendar).due.isEmpty)

        state.setTaskArchived(task.id, archived: false, at: now.addingTimeInterval(1))
        let restored = try #require(state.task(task.id))
        #expect(!restored.isArchived)
        #expect(restored.isNagging(at: now))
        #expect(restored.startAt == task.startAt)
    }

    @Test func archiveAndRestoreSurviveStaleEdits() throws {
        let now = Fixture.date(28, 9)
        let original = NagTask(title: "Water plants", now: now)
        var state = NagState(tasks: [original])
        state.setTaskArchived(original.id, archived: true, at: now.addingTimeInterval(1))
        let archived = try #require(state.task(original.id))

        var edited = original
        edited.title = "Water and rotate plants"
        edited.updatedAt = now.addingTimeInterval(3)
        let merged = TaskMerge.merge(edited, archived)
        #expect(merged.isArchived)
        #expect(merged.title == edited.title)
        var editedState = state
        #expect(editedState.save(edited, now: edited.updatedAt).isArchived)

        state.setTaskArchived(original.id, archived: false, at: now.addingTimeInterval(2))
        let restored = try #require(state.task(original.id))
        #expect(!TaskMerge.merge(merged, restored).isArchived)
    }
}
