import Foundation
import Testing
@testable import NagCore

@Suite struct Milestone1Issue11RepeatCompatibilityTests {
    private enum ShippedRepeatRule: String, Decodable {
        case never, daily, weekdays, weekly, custom
    }

    private struct ShippedTask: Decodable {
        var title: String
        var repeatRule: ShippedRepeatRule
    }

    private struct ShippedSyncedTasks: Decodable {
        var tasks: [ShippedTask]
        var deleted: [String: Date]
    }

    @Test func wholeBlobRemainsDecodableByShippedRepeatRuleDecoder() throws {
        let current = SyncedTasks(tasks: [
            NagTask(title: "Water", repeatRule: .everyNDays, repeatEvery: 3),
            NagTask(title: "Rent", repeatRule: .monthly, monthDay: 31),
        ])

        let shipped = try JSONDecoder().decode(
            ShippedSyncedTasks.self,
            from: JSONEncoder().encode(current)
        )

        #expect(shipped.tasks.map(\.title) == ["Water", "Rent"])
        #expect(shipped.tasks.map(\.repeatRule) == [.daily, .daily])
        #expect(shipped.deleted.isEmpty)
    }

    @Test func decodedRepeatParametersClampToSupportedRanges() throws {
        var tooSmall = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(NagTask(title: "Small", repeatRule: .everyNDays))
            ) as? [String: Any]
        )
        tooSmall["repeatEvery"] = -10
        var tooLarge = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(NagTask(title: "Large", repeatRule: .monthly))
            ) as? [String: Any]
        )
        tooLarge["monthDay"] = 99

        let every = try JSONDecoder().decode(
            NagTask.self, from: JSONSerialization.data(withJSONObject: tooSmall)
        )
        let monthly = try JSONDecoder().decode(
            NagTask.self, from: JSONSerialization.data(withJSONObject: tooLarge)
        )

        #expect(every.repeatEvery == 1)
        #expect(monthly.monthDay == 31)
        #expect(every.hasValidSchedule)
        #expect(monthly.hasValidSchedule)
    }

    @Test func monthlyCompletionAfterShortMonthReturnsToPreferredDay() {
        let calendar = Fixture.calendar
        let january = calendar.date(from: DateComponents(year: 2024, month: 1, day: 31, hour: 8))!
        let february = calendar.date(from: DateComponents(year: 2024, month: 2, day: 29, hour: 8))!
        let march = calendar.date(from: DateComponents(year: 2024, month: 3, day: 31, hour: 8))!
        var task = NagTask(title: "Month end", startAt: january, repeatRule: .monthly, monthDay: 31)

        task.complete(at: january, calendar: calendar)
        #expect(task.startAt == february)
        task.complete(at: february, calendar: calendar)
        #expect(task.startAt == march)
        #expect(task.monthDay == 31)
    }
}
