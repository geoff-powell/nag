import Foundation
import Testing
@testable import NagCore

@Suite struct NagAlarmTests {
    let calendar = Fixture.calendar
    let start = Fixture.date(28, 12)

    @Test func existingStylesDefaultToNotifications() throws {
        let style = try JSONDecoder().decode(NagStyle.self, from: Data("{}".utf8))
        #expect(style.alarmMode == .off)
    }

    @Test func alarmModesUseStartOrHighestTier() {
        var task = NagTask(title: "Medication", startAt: start)
        #expect(date(for: task) == nil)
        task.style.alarmMode = .atStart
        #expect(date(for: task) == start)
        task.style.alarmMode = .atTopTier
        #expect(date(for: task) == start.addingTimeInterval(3 * 3600))

        let snoozedUntil = start.addingTimeInterval(4 * 3600)
        task.snoozedUntil = snoozedUntil
        #expect(date(for: task) == snoozedUntil)

        task.startedAt = start
        #expect(date(for: task) == nil)
    }

    private func date(for task: NagTask) -> Date? {
        task.alarmDate(quietHours: QuietHours(), focusFilter: FocusFilter(), calendar: calendar)
    }
}
