import Foundation
import Testing
@testable import NagCore

@Suite struct Milestone1Issue7CompatibilityTests {
    let calendar = Fixture.calendar

    @Test func payloadFromBeforeUndoFieldsStillDecodes() throws {
        let original = NagTask(
            title: "Old task",
            startAt: Fixture.date(28, 8),
            repeatRule: .daily,
            now: Fixture.date(27, 8)
        )
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "completionUndo")
        json.removeValue(forKey: "undoneCompletionAt")

        let decoded = try JSONDecoder().decode(
            NagTask.self,
            from: JSONSerialization.data(withJSONObject: json)
        )

        #expect(decoded == original)
        #expect(decoded.completionUndo == nil)
        #expect(decoded.undoneCompletionAt == nil)
    }

    @Test func undoWindowIsExclusiveAtTenMinutes() {
        let completedAt = Fixture.date(28, 9)
        var task = NagTask(title: "Taxes", startAt: Fixture.date(28, 8), now: Fixture.date(27, 8))
        task.complete(at: completedAt, calendar: calendar)

        #expect(task.canUndoCompletion(at: completedAt.addingTimeInterval(NagUndo.window - 1)))
        #expect(!task.canUndoCompletion(at: completedAt.addingTimeInterval(NagUndo.window)))
    }

    @Test func undoMetadataSurvivesSyncedTasksRoundTrip() throws {
        var task = NagTask(
            title: "Meds",
            startAt: Fixture.date(28, 8),
            repeatRule: .daily,
            now: Fixture.date(27, 8)
        )
        task.complete(at: Fixture.date(28, 9), calendar: calendar)
        let didUndo = task.undoCompletion(at: Fixture.date(28, 9, 1))
        #expect(didUndo)

        let decoded = try JSONDecoder().decode(
            SyncedTasks.self,
            from: JSONEncoder().encode(SyncedTasks(tasks: [task]))
        )

        #expect(decoded.tasks == [task])
        #expect(decoded.tasks.first?.undoneCompletionAt == Fixture.date(28, 9))
    }
}
