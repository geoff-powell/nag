import Foundation
import Testing
@testable import NagCore

@Suite struct Milestone1Issue13ToneCompatibilityTests {
    private struct ShippedStyle: Decodable {
        var intervalMinutes: Int
        var escalation: Escalation
        var snoozeMinutes: Int
        var maxSnoozes: Int?
        var breakThroughFocus: Bool
        var workMinutes: Int
    }

    @Test func shippedStyleDecoderIgnoresNewToneKey() throws {
        let encoded = try JSONEncoder().encode(NagStyle(
            intervalMinutes: 5,
            escalation: .relentless,
            snoozeMinutes: 15,
            maxSnoozes: 2,
            breakThroughFocus: false,
            workMinutes: 45,
            tone: .pushy
        ))

        let shipped = try JSONDecoder().decode(ShippedStyle.self, from: encoded)

        #expect(shipped.intervalMinutes == 5)
        #expect(shipped.escalation == .relentless)
        #expect(shipped.snoozeMinutes == 15)
        #expect(shipped.maxSnoozes == 2)
        #expect(shipped.breakThroughFocus == false)
        #expect(shipped.workMinutes == 45)
    }

    @Test func changingOnlyPerNagOverrideChangesIdentifierAndBody() {
        let planner = NagPlanner(calendar: Fixture.calendar)
        var task = NagTask(
            title: "Laundry",
            startAt: Fixture.date(28, 8),
            now: Fixture.date(28, 7)
        )
        let inherited = planner.plan(
            tasks: [task], quietHours: QuietHours(), tone: .gentle, now: Fixture.date(28, 12)
        )
        task.style.tone = .pushy
        let overridden = planner.plan(
            tasks: [task], quietHours: QuietHours(), tone: .gentle, now: Fixture.date(28, 12)
        )

        #expect(inherited.notifications.first?.identifier != overridden.notifications.first?.identifier)
        #expect(inherited.notifications.first?.body
            == NagMessages.repeatingBody(title: task.title, tier: 3, tone: .gentle))
        #expect(overridden.notifications.first?.body
            == NagMessages.repeatingBody(title: task.title, tier: 3, tone: .pushy))
    }

    @Test func nullAndUnknownToneBothDecodeAsNoOverride() throws {
        for value: Any in [NSNull(), "future-tone"] {
            var json = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(NagStyle(tone: .gentle))) as? [String: Any]
            )
            json["tone"] = value
            let decoded = try JSONDecoder().decode(
                NagStyle.self,
                from: JSONSerialization.data(withJSONObject: json)
            )
            #expect(decoded.tone == nil)
        }
    }
}
