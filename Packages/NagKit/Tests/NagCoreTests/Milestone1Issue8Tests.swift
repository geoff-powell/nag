import Foundation
import Testing
@testable import NagCore

@Suite struct Milestone1Issue8StartedEdgeTests {
    @Test func startingTwiceKeepsTheOriginalWorkingWindow() {
        var task = NagTask(
            title: "Laundry",
            startAt: Fixture.date(28, 8),
            style: NagStyle(workMinutes: 30),
            now: Fixture.date(28, 7)
        )
        task.start(at: Fixture.date(28, 9))
        let firstStartedAt = task.startedAt
        let firstUpdatedAt = task.updatedAt

        task.start(at: Fixture.date(28, 9, 10))

        #expect(task.startedAt == firstStartedAt)
        #expect(task.updatedAt == firstUpdatedAt)
        #expect(task.workingUntil() == Fixture.date(28, 9, 30))
    }

    @Test func syncedPayloadWithoutStartedFieldsUsesShippedDefaults() throws {
        let task = NagTask(
            title: "Old task",
            startAt: Fixture.date(28, 9),
            style: NagStyle(intervalMinutes: 5, workMinutes: 45),
            now: Fixture.date(27, 9)
        )
        var root = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(SyncedTasks(tasks: [task]))) as? [String: Any]
        )
        var tasks = try #require(root["tasks"] as? [[String: Any]])
        tasks[0].removeValue(forKey: "startedAt")
        var style = try #require(tasks[0]["style"] as? [String: Any])
        style.removeValue(forKey: "workMinutes")
        tasks[0]["style"] = style
        root["tasks"] = tasks

        let decoded = try JSONDecoder().decode(
            SyncedTasks.self,
            from: JSONSerialization.data(withJSONObject: root)
        )

        #expect(decoded.tasks.count == 1)
        #expect(decoded.tasks[0].startedAt == nil)
        #expect(decoded.tasks[0].style.workMinutes == 30)
    }

    @Test func startedPlannerIdentifierAndCopyStayStableWhenNothingChanges() {
        var task = NagTask(
            title: "Laundry",
            startAt: Fixture.date(28, 8),
            style: NagStyle(intervalMinutes: 15, workMinutes: 30),
            now: Fixture.date(28, 7)
        )
        task.start(at: Fixture.date(28, 9))
        let planner = NagPlanner(calendar: Fixture.calendar)

        let first = planner.plan(tasks: [task], quietHours: QuietHours(), now: Fixture.date(28, 9, 31))
        let second = planner.plan(tasks: [task], quietHours: QuietHours(), now: Fixture.date(28, 9, 32))

        #expect(first.notifications.first?.identifier == second.notifications.first?.identifier)
        #expect(first.notifications.first?.body == NagMessages.checkInRepeatingBody(title: task.title))
    }
}
