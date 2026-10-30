import Foundation
import Testing
@testable import NagCore

@Suite struct Milestone1Issue12QuietHoursLWWTests {
    @Test func equalTimestampTieBreakUsesEveryTupleComponent() {
        let stamp = Fixture.date(28, 9)
        let disabled = SyncedQuietHours(
            quietHours: QuietHours(enabled: false, startMinute: 23 * 60, endMinute: 9 * 60),
            updatedAt: stamp
        )
        let enabled = SyncedQuietHours(
            quietHours: QuietHours(enabled: true, startMinute: 1, endMinute: 1),
            updatedAt: stamp
        )
        let earlierStart = SyncedQuietHours(
            quietHours: QuietHours(enabled: true, startMinute: 21 * 60, endMinute: 9 * 60),
            updatedAt: stamp
        )
        let laterStart = SyncedQuietHours(
            quietHours: QuietHours(enabled: true, startMinute: 22 * 60, endMinute: 8 * 60),
            updatedAt: stamp
        )
        let laterEnd = SyncedQuietHours(
            quietHours: QuietHours(enabled: true, startMinute: 22 * 60, endMinute: 9 * 60),
            updatedAt: stamp
        )

        #expect(QuietHoursMerge.merge(disabled, enabled) == enabled)
        #expect(QuietHoursMerge.merge(enabled, disabled) == enabled)
        #expect(QuietHoursMerge.merge(earlierStart, laterStart) == laterStart)
        #expect(QuietHoursMerge.merge(laterStart, earlierStart) == laterStart)
        #expect(QuietHoursMerge.merge(laterStart, laterEnd) == laterEnd)
        #expect(QuietHoursMerge.merge(laterEnd, laterStart) == laterEnd)
    }

    @Test func mergeIsAssociativeAcrossThreeDevices() {
        let values = [
            SyncedQuietHours(
                quietHours: QuietHours(enabled: true, startMinute: 21 * 60, endMinute: 7 * 60),
                updatedAt: Fixture.date(28, 8)
            ),
            SyncedQuietHours(
                quietHours: QuietHours(enabled: false, startMinute: 22 * 60, endMinute: 8 * 60),
                updatedAt: Fixture.date(28, 9)
            ),
            SyncedQuietHours(
                quietHours: QuietHours(enabled: true, startMinute: 23 * 60, endMinute: 9 * 60),
                updatedAt: Fixture.date(28, 9)
            ),
        ]

        let left = QuietHoursMerge.merge(QuietHoursMerge.merge(values[0], values[1]), values[2])
        let right = QuietHoursMerge.merge(values[0], QuietHoursMerge.merge(values[1], values[2]))

        #expect(left == right)
        #expect(left == values[2])
    }

    @Test func applyingRemoteQuietHoursLeavesDeviceLocalSettingsAlone() {
        let used = [Fixture.date(28, 8)]
        var settings = AppSettings(
            emergencyUnlocksPerMonth: 7,
            emergencyUnlocksUsed: used,
            hasOnboarded: true,
            screenTimeApproved: true
        )
        let remote = SyncedQuietHours(
            quietHours: QuietHours(enabled: true, startMinute: 23 * 60, endMinute: 7 * 60),
            updatedAt: Fixture.date(28, 9)
        )

        settings.apply(remote)

        #expect(settings.quietHours == remote.quietHours)
        #expect(settings.quietHoursUpdatedAt == remote.updatedAt)
        #expect(settings.emergencyUnlocksPerMonth == 7)
        #expect(settings.emergencyUnlocksUsed == used)
        #expect(settings.hasOnboarded)
        #expect(settings.screenTimeApproved)
    }
}
