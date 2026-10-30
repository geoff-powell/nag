import Foundation
import Testing
@testable import NagCore

struct NagRequestTests {
    let calendar = Fixture.calendar
    let now = Fixture.date(28, 10)

    @Test func addsANewNagStartingNow() throws {
        var state = NagState()
        let draft = try state.apply(NagRequest(title: "  Call mum  ", source: "Claude"), now: now, calendar: calendar)
        #expect(draft.isNew)
        #expect(state.tasks.count == 1)
        #expect(state.tasks[0].title == "Call mum")
        #expect(state.tasks[0].startAt == now)
        #expect(state.tasks[0].repeatRule == .never)
        #expect(state.tasks[0].source == "Claude")
        #expect(state.tasks[0].externalID == nil)
    }

    @Test func blankTitleIsRejected() {
        var state = NagState()
        #expect(throws: NagRequestError.missingTitle) {
            try state.apply(NagRequest(title: "  "), now: now, calendar: calendar)
        }
        #expect(state.tasks.isEmpty)
    }

    @Test func timesImplyACustomScheduleStartingAtTheNextTime() throws {
        var state = NagState()
        let request = NagRequest(title: "Pills", times: [NagTime(minute: 21 * 60, weekdays: [4])])
        let task = try state.apply(request, now: now, calendar: calendar).task
        #expect(task.repeatRule == .custom)
        #expect(task.startAt == Fixture.date(28, 21))
    }

    @Test func customWithoutTimesIsRejected() {
        var state = NagState()
        #expect(throws: NagRequestError.invalidSchedule) {
            try state.apply(NagRequest(title: "Pills", repeatRule: .custom), now: now, calendar: calendar)
        }
    }

    @Test func outOfRangeValuesAreRejected() {
        var state = NagState()
        #expect(throws: NagRequestError.self) {
            try state.apply(NagRequest(title: "x", intervalMinutes: 0), now: now, calendar: calendar)
        }
        #expect(throws: NagRequestError.self) {
            try state.apply(NagRequest(title: "x", snoozeLimit: .limited(-1)), now: now, calendar: calendar)
        }
    }

    @Test func sameSourceItemUpdatesInsteadOfDuplicating() throws {
        var state = NagState()
        let first = try state.apply(
            NagRequest(title: "Dentist", startAt: Fixture.date(29, 9), intervalMinutes: 5, source: "Calendar", externalID: "evt-1"),
            now: now, calendar: calendar
        ).task

        let moved = try state.apply(
            NagRequest(title: "Dentist (moved)", startAt: Fixture.date(30, 9), source: "Calendar", externalID: "evt-1"),
            now: Fixture.date(28, 11), calendar: calendar
        )
        #expect(!moved.isNew)
        #expect(state.tasks.count == 1)
        #expect(state.tasks[0].id == first.id)
        #expect(state.tasks[0].title == "Dentist (moved)")
        #expect(state.tasks[0].startAt == Fixture.date(30, 9))
        // Fields the request left out keep their values.
        #expect(state.tasks[0].style.intervalMinutes == 5)
        #expect(state.tasks[0].updatedAt == Fixture.date(28, 11))
    }

    @Test func sameIDFromAnotherSourceIsANewNag() throws {
        var state = NagState()
        try state.apply(NagRequest(title: "A", source: "Calendar", externalID: "1"), now: now, calendar: calendar)
        try state.apply(NagRequest(title: "B", source: "Muse", externalID: "1"), now: now, calendar: calendar)
        #expect(state.tasks.count == 2)
    }

    @Test func resendingAnUnchangedItemChangesNothing() throws {
        var state = NagState()
        let request = NagRequest(title: "Dentist", startAt: Fixture.date(29, 9), source: "Calendar", externalID: "evt-1")
        try state.apply(request, now: now, calendar: calendar)
        let before = state
        try state.apply(request, now: Fixture.date(28, 12), calendar: calendar)
        #expect(state == before)
    }

    @Test func movingAFinishedOneOffReopensIt() throws {
        var state = NagState()
        let request = NagRequest(title: "Dentist", startAt: Fixture.date(28, 9), source: "Calendar", externalID: "evt-1")
        try state.apply(request, now: now, calendar: calendar)
        state.tasks[0].complete(at: now, calendar: calendar)

        // Sent again unchanged: stays done.
        try state.apply(request, now: Fixture.date(28, 11), calendar: calendar)
        #expect(state.tasks[0].isFinished)

        var moved = request
        moved.startAt = Fixture.date(30, 9)
        try state.apply(moved, now: Fixture.date(28, 11), calendar: calendar)
        #expect(!state.tasks[0].isFinished)
    }

    @Test func saveResetsSnoozesWhenTheStartMoves() {
        var state = NagState()
        var task = NagTask(title: "Snoozy", startAt: Fixture.date(28, 9), now: Fixture.date(28, 8))
        task.snoozeCount = 2
        task.snoozedUntil = Fixture.date(28, 10)
        state.tasks = [task]

        task.title = " Snoozy "
        state.save(task, now: now)
        #expect(state.tasks[0].snoozeCount == 2)
        #expect(state.tasks[0].title == "Snoozy")

        task.startAt = Fixture.date(29, 9)
        state.save(task, now: now)
        #expect(state.tasks[0].snoozeCount == 0)
        #expect(state.tasks[0].snoozedUntil == nil)
    }

    @Test func duplicateDropsTheExternalID() {
        let task = NagTask(title: "From Muse", source: "Muse", externalID: "card", link: URL(string: "https://example.com"), now: now)
        let copy = task.duplicate(now: now)
        #expect(copy.source == "Muse")
        #expect(copy.link == task.link)
        #expect(copy.externalID == nil)
    }

    @Test func oldNagsWithoutSourceStillDecode() throws {
        let task = NagTask(title: "Old", now: now)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as! [String: Any]
        json.removeValue(forKey: "source")
        json.removeValue(forKey: "externalID")
        json.removeValue(forKey: "link")
        let decoded = try JSONDecoder().decode(NagTask.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == task)

        let tagged = NagTask(title: "New", source: "Calendar", externalID: "e", link: URL(string: "https://example.com"), now: now)
        #expect(try JSONDecoder().decode(NagTask.self, from: JSONEncoder().encode(tagged)) == tagged)
    }
}

struct NagLinkTests {
    let calendar = Fixture.calendar
    let now = Fixture.date(28, 10)

    private func request(_ string: String) throws -> NagRequest {
        try NagRequest(url: URL(string: string)!, now: now, calendar: calendar)
    }

    @Test func minimalLink() throws {
        let request = try self.request("nag://add?title=Take%20pills")
        #expect(request == NagRequest(title: "Take pills"))
    }

    @Test func plusMeansSpaceAndEncodedPlusIsKept() throws {
        #expect(try request("nag://add?title=Buy+milk+%2B+eggs").title == "Buy milk + eggs")
    }

    @Test func everyParameter() throws {
        let request = try self.request(
            "nag://add?text=Stretch&notes=Just%20one&at=2026-10-29T08:30&repeat=weekdays&every=5"
                + "&escalation=relentless&snooze=15&snoozes=unlimited&focus=no&source=Muse&id=card-42"
                + "&link=https%3A%2F%2Fmuse.app%2Fcard"
        )
        #expect(request.title == "Stretch")
        #expect(request.notes == "Just one")
        #expect(request.startAt == Fixture.date(29, 8, 30))
        #expect(request.repeatRule == .weekdays)
        #expect(request.intervalMinutes == 5)
        #expect(request.escalation == .relentless)
        #expect(request.snoozeMinutes == 15)
        #expect(request.snoozeLimit == .unlimited)
        #expect(request.breakThroughFocus == false)
        #expect(request.source == "Muse")
        #expect(request.externalID == "card-42")
        #expect(request.link == URL(string: "https://muse.app/card"))
    }

    @Test func startFormats() throws {
        #expect(try request("nag://add?title=x&at=2026-10-29T08:30:00Z").startAt == Fixture.date(29, 8, 30))
        #expect(try request("nag://add?title=x&at=2026-10-29T10:30:00%2B02:00").startAt == Fixture.date(29, 8, 30))
        #expect(try request("nag://add?title=x&at=2026-10-30").startAt == Fixture.date(30, 9))
        // A time later today is today; one that's passed is tomorrow.
        #expect(try request("nag://add?title=x&at=17:30").startAt == Fixture.date(28, 17, 30))
        #expect(try request("nag://add?title=x&at=08:00").startAt == Fixture.date(29, 8))
        #expect(try request("nag://add?title=x&in=1h30m").startAt == Fixture.date(28, 11, 30))
        #expect(try request("nag://add?title=x&in=45").startAt == Fixture.date(28, 10, 45))
    }

    @Test func customTimesAndDays() throws {
        let request = try self.request("nag://add?title=Pills&times=09:00,21:30&days=mon,Wednesday,fri")
        #expect(request.times?.map(\.minute) == [540, 1290])
        #expect(request.times?.allSatisfy { $0.weekdays == [2, 4, 6] } == true)

        let daysOnly = try self.request("nag://add?title=Gym&at=2026-10-29T07:15&days=weekends")
        #expect(daysOnly.times?.map(\.minute) == [7 * 60 + 15])
        #expect(daysOnly.times?.first?.weekdays == [1, 7])
    }

    @Test func badLinksAreRejected() {
        #expect(throws: NagRequestError.unsupportedURL) { try request("https://example.com/add?title=x") }
        #expect(throws: NagRequestError.unsupportedURL) { try request("nag://delete?title=x") }
        #expect(throws: NagRequestError.self) { try request("nag://add?title=x&repeat=hourly") }
        #expect(throws: NagRequestError.self) { try request("nag://add?title=x&at=tomorrowish") }
        #expect(throws: NagRequestError.self) { try request("nag://add?title=x&times=25:00") }
        #expect(throws: NagRequestError.self) { try request("nag://add?title=x&days=funday") }
        #expect(throws: NagRequestError.self) { try request("nag://add?title=x&every=0") }
        #expect(throws: NagRequestError.self) { try request("nag://add?title=x&link=not%20a%20url") }
    }

    @Test func linkWithoutTitleParsesButCantBeSaved() throws {
        let request = try self.request("nag://add?notes=hi")
        var state = NagState()
        #expect(throws: NagRequestError.missingTitle) { try state.apply(request, now: now, calendar: calendar) }
    }
}
