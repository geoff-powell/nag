import Foundation
import Testing
@testable import NagCore

@Suite struct Milestone1Issue10PresetInvariantTests {
    let calendar = Fixture.calendar

    @Test func everyPresetHasUsableDisplayMetadataAndStableOrder() {
        #expect(NagPreset.all.map(\.id) == ["medication", "chore", "appointment", "someday"])
        #expect(NagPreset.all.allSatisfy { !$0.name.isEmpty && !$0.symbol.isEmpty && !$0.summary.isEmpty })
    }

    @Test func nonMedicationPresetsAlwaysRestoreTapDoneProof() {
        for preset in [NagPreset.chore, .appointment, .someday] {
            var task = NagTask(title: preset.name, proof: .scanKey(UUID()))
            preset.apply(to: &task, keys: [], now: Fixture.date(28, 9), calendar: calendar)
            #expect(task.proof == .none)
        }
    }

    @Test func applyingPresetDoesNotResetProgress() {
        var task = NagTask(
            title: "Laundry",
            startAt: Fixture.date(28, 8),
            repeatRule: .daily,
            now: Fixture.date(27, 8)
        )
        task.snoozeCount = 2
        task.snoozedUntil = Fixture.date(28, 10)
        task.startedAt = Fixture.date(28, 9)
        task.lastCompletedAt = Fixture.date(27, 9)
        let progress = (task.snoozeCount, task.snoozedUntil, task.startedAt, task.lastCompletedAt)

        NagPreset.appointment.apply(
            to: &task, keys: [], now: Fixture.date(28, 9, 30), calendar: calendar
        )

        #expect(task.snoozeCount == progress.0)
        #expect(task.snoozedUntil == progress.1)
        #expect(task.startedAt == progress.2)
        #expect(task.lastCompletedAt == progress.3)
    }
}
