import Foundation
import Testing
@testable import NagCore

@Suite struct Milestone3Issue25Tests {
    let calendar = Fixture.calendar
    let home = SavedPlace(name: "Home", latitude: 51.5, longitude: -0.12)
    let office = SavedPlace(name: "Office", latitude: 51.52, longitude: -0.08)

    private func placeNag(
        _ title: String = "Bins",
        at place: SavedPlace? = nil,
        event: PlaceEvent = .arrive,
        repeats: Bool = true
    ) -> NagTask {
        NagTask(
            title: title,
            startAt: PlaceTrigger.waitingStart,
            placeTrigger: PlaceTrigger(place: (place ?? home).ref, event: event, repeats: repeats),
            now: Fixture.date(28, 7)
        )
    }

    private func state(tasks: [NagTask] = [], profiles: [LockProfile] = [], outsideHome: Bool = true) -> NagState {
        var state = NagState(tasks: tasks, profiles: profiles, places: [home, office])
        if outsideHome {
            state.placePresence[home.id.uuidString] = PlacePresence(inside: false, since: Fixture.date(28, 6))
        }
        return state
    }

    // MARK: Nags

    @Test func waitingPlaceNagNeverNagsOrPlansNotifications() {
        let nag = placeNag()
        #expect(nag.isAwaitingPlace)
        #expect(!nag.isOutstanding(at: Fixture.date(28, 12)))
        let plan = NagPlanner(calendar: calendar).plan(tasks: [nag], quietHours: QuietHours(), now: Fixture.date(28, 12))
        #expect(plan.notifications.isEmpty)
        #expect(plan.nextWake == nil)
        #expect(WidgetSnapshot.make(from: NagState(tasks: [nag]), now: Fixture.date(28, 12), calendar: calendar).nextChange == nil)
    }

    @Test func arrivingStartsTheNagWithNormalNagging() {
        var state = state(tasks: [placeNag()])
        let now = Fixture.date(28, 18)
        let started = state.applyPlaceObservation(placeID: home.id, inside: true, now: now)
        #expect(started == [state.tasks[0].id])
        #expect(state.tasks[0].startAt == now)
        #expect(state.tasks[0].updatedAt == now)
        #expect(state.tasks[0].isNagging(at: now))
        let plan = NagPlanner(calendar: calendar).plan(tasks: state.tasks, quietHours: QuietHours(), now: now)
        #expect(plan.notifications.count == 1)
    }

    @Test func duplicateArrivalsAreIgnored() {
        var state = state(tasks: [placeNag()])
        state.applyPlaceObservation(placeID: home.id, inside: true, now: Fixture.date(28, 18))
        let before = state
        do {
            let started = state.applyPlaceObservation(placeID: home.id, inside: true, now: Fixture.date(28, 18, 5))
            #expect(started.isEmpty)
        }
        #expect(state == before)
    }

    @Test func firstReportIsNotAnArrival() {
        var state = state(tasks: [placeNag()], outsideHome: false)
        do {
            let started = state.applyPlaceObservation(placeID: home.id, inside: true, now: Fixture.date(28, 18))
            #expect(started.isEmpty)
        }
        #expect(state.tasks[0].isAwaitingPlace)
        #expect(state.isInside(home.id))
    }

    @Test func leaveNagsStartOnLeavingOnly() {
        var state = state(tasks: [placeNag("Lock door", event: .leave)])
        state.placePresence[home.id.uuidString] = PlacePresence(inside: true, since: Fixture.date(28, 6))
        do {
            let started = state.applyPlaceObservation(placeID: home.id, inside: true, now: Fixture.date(28, 8))
            #expect(started.isEmpty)
        }
        do {
            let started = state.applyPlaceObservation(placeID: home.id, inside: false, now: Fixture.date(28, 9))
            #expect(started.count == 1)
        }
    }

    @Test func otherPlacesDoNotStartTheNag() {
        var state = state(tasks: [placeNag()])
        state.placePresence[office.id.uuidString] = PlacePresence(inside: false, since: Fixture.date(28, 6))
        do {
            let started = state.applyPlaceObservation(placeID: office.id, inside: true, now: Fixture.date(28, 9))
            #expect(started.isEmpty)
        }
    }

    @Test func repeatingPlaceNagWaitsAgainAfterDoneAndRestartsOnNextArrival() {
        var state = state(tasks: [placeNag()])
        state.applyPlaceObservation(placeID: home.id, inside: true, now: Fixture.date(28, 18))
        state.tasks[0].complete(at: Fixture.date(28, 18, 10), calendar: calendar)
        #expect(state.tasks[0].isAwaitingPlace)
        #expect(!state.tasks[0].isFinished)
        #expect(state.tasks[0].lastCompletedAt == Fixture.date(28, 18, 10))
        #expect(state.tasks[0].isSatisfied(at: Fixture.date(28, 19), calendar: calendar))
        #expect(!state.tasks[0].canComplete(at: Fixture.date(28, 19), calendar: calendar))

        state.applyPlaceObservation(placeID: home.id, inside: false, now: Fixture.date(29, 8))
        do {
            let started = state.applyPlaceObservation(placeID: home.id, inside: true, now: Fixture.date(29, 18))
            #expect(started.count == 1)
        }
        #expect(state.tasks[0].isNagging(at: Fixture.date(29, 18)))
    }

    @Test func undoingADoneRepeatingPlaceNagStartsNaggingAgain() {
        var nag = placeNag()
        nag.startForPlace(at: Fixture.date(28, 18))
        nag.complete(at: Fixture.date(28, 18, 10), calendar: calendar)
        let undone = nag.undoCompletion(at: Fixture.date(28, 18, 11))
        #expect(undone)
        #expect(nag.isNagging(at: Fixture.date(28, 18, 11)))
    }

    @Test func oneOffPlaceNagFinishesAndIgnoresLaterArrivals() {
        var state = state(tasks: [placeNag("Buy milk", repeats: false)])
        state.applyPlaceObservation(placeID: home.id, inside: true, now: Fixture.date(28, 18))
        state.tasks[0].complete(at: Fixture.date(28, 18, 10), calendar: calendar)
        #expect(state.tasks[0].isFinished)
        #expect(state.tasks[0].isClearable)
        state.applyPlaceObservation(placeID: home.id, inside: false, now: Fixture.date(29, 8))
        do {
            let started = state.applyPlaceObservation(placeID: home.id, inside: true, now: Fixture.date(29, 18))
            #expect(started.isEmpty)
        }
    }

    @Test func repeatingPlaceNagDoneByAnOlderBuildRestartsAndIsNotClearable() {
        var nag = placeNag()
        nag.startForPlace(at: Fixture.date(28, 18))
        // Older builds see `.never` and set completedAt.
        nag.completedAt = Fixture.date(28, 18, 5)
        #expect(!nag.isClearable)
        let restarted = nag.startForPlace(at: Fixture.date(29, 18))
        #expect(restarted)
        #expect(nag.completedAt == nil)
    }

    @Test func unknownPlacesAreShownAsAnotherDeviceAndNeverStart() {
        let elsewhere = PlaceRef(id: UUID(), name: "Gym")
        var nag = placeNag()
        nag.placeTrigger?.place = elsewhere
        var state = state(tasks: [nag])
        #expect(state.placeName(elsewhere) == "Gym (another device)")
        #expect(state.unknownPlaceRefs == [elsewhere])
        state.applyPlaceObservation(placeID: home.id, inside: true, now: Fixture.date(28, 18))
        #expect(state.tasks[0].isAwaitingPlace)
        do {
            let started = state.applyPlaceObservation(placeID: elsewhere.id, inside: true, now: Fixture.date(28, 18))
            #expect(started.isEmpty)
        }
    }

    @Test func linkingAnUnknownPlaceMakesItWorkOnThisDevice() {
        let elsewhere = PlaceRef(id: UUID(), name: "Home")
        var nag = placeNag()
        nag.placeTrigger?.place = elsewhere
        var state = state(tasks: [nag])
        state.linkPlace(elsewhere, to: home.id)
        #expect(state.placeName(elsewhere) == "Home")
        #expect(state.unknownPlaceRefs.isEmpty)
        do {
            let started = state.applyPlaceObservation(placeID: home.id, inside: true, now: Fixture.date(28, 18))
            #expect(started.count == 1)
        }
        // The synced nag itself is untouched.
        #expect(state.tasks[0].placeTrigger?.place == elsewhere)
    }

    @Test func deletingAPlaceForgetsPresenceAndLinks() {
        var state = state()
        state.linkPlace(PlaceRef(id: UUID(), name: "Home"), to: home.id)
        state.deletePlace(home.id)
        #expect(state.places == [office])
        #expect(state.placePresence.isEmpty)
        #expect(state.placeLinks.isEmpty)
    }

    // MARK: Locks

    private func placeLock(at place: SavedPlace) -> LockProfile {
        LockProfile(name: "Social", place: place.ref)
    }

    @Test func placeLockSwitchesOnOnArrivalAndOffOnLeaving() {
        var state = state(profiles: [placeLock(at: home)])
        state.applyPlaceObservation(placeID: home.id, inside: true, now: Fixture.date(28, 9))
        LockMaintenance.run(&state, now: Fixture.date(28, 9), calendar: calendar)
        #expect(state.profiles[0].isLocked)
        #expect(state.profiles[0].session?.trigger == .place)

        state.applyPlaceObservation(placeID: home.id, inside: false, now: Fixture.date(28, 17))
        LockMaintenance.run(&state, now: Fixture.date(28, 17), calendar: calendar)
        #expect(state.profiles[0].status == .off)
    }

    @Test func placeLockEngagesWhenAlreadyThere() {
        var state = state(profiles: [placeLock(at: home)], outsideHome: false)
        state.applyPlaceObservation(placeID: home.id, inside: true, now: Fixture.date(28, 9))
        LockMaintenance.run(&state, now: Fixture.date(28, 9), calendar: calendar)
        #expect(state.profiles[0].isLocked)
    }

    @Test func earningAnUnlockMidVisitSticksUntilTheNextArrival() {
        var state = state(profiles: [placeLock(at: home)])
        state.applyPlaceObservation(placeID: home.id, inside: true, now: Fixture.date(28, 9))
        LockMaintenance.run(&state, now: Fixture.date(28, 9), calendar: calendar)
        state.profiles[0].emergencyUnlock(at: Fixture.date(28, 10))
        LockMaintenance.run(&state, now: Fixture.date(28, 11), calendar: calendar)
        #expect(state.profiles[0].status == .off)

        state.applyPlaceObservation(placeID: home.id, inside: false, now: Fixture.date(28, 17))
        state.applyPlaceObservation(placeID: home.id, inside: true, now: Fixture.date(29, 9))
        LockMaintenance.run(&state, now: Fixture.date(29, 9), calendar: calendar)
        #expect(state.profiles[0].isLocked)
    }

    @Test func timedUnlockOfAPlaceLockOnlyComesBackWhileStillThere() {
        var lock = placeLock(at: home)
        lock.requirements = [UnlockRequirement(kind: .wait(minutes: 5))]
        lock.unlockMinutes = 30
        var state = state(profiles: [lock])
        state.applyPlaceObservation(placeID: home.id, inside: true, now: Fixture.date(28, 9))
        LockMaintenance.run(&state, now: Fixture.date(28, 9), calendar: calendar)
        state.profiles[0].grantUnlock(at: Fixture.date(28, 10))
        LockMaintenance.run(&state, now: Fixture.date(28, 10, 31), calendar: calendar)
        #expect(state.profiles[0].isLocked)

        state.profiles[0].grantUnlock(at: Fixture.date(28, 11))
        state.applyPlaceObservation(placeID: home.id, inside: false, now: Fixture.date(28, 11, 10))
        LockMaintenance.run(&state, now: Fixture.date(28, 11, 31), calendar: calendar)
        #expect(state.profiles[0].status == .off)
    }

    @Test func placeLocksIgnoreOtherTriggers() {
        var lock = placeLock(at: home)
        lock.lock(at: Fixture.date(28, 8))
        var state = state(profiles: [lock])
        state.applyPlaceObservation(placeID: home.id, inside: true, now: Fixture.date(28, 9))
        state.applyPlaceObservation(placeID: home.id, inside: false, now: Fixture.date(28, 10))
        LockMaintenance.run(&state, now: Fixture.date(28, 10), calendar: calendar)
        #expect(state.profiles[0].isLocked)
        #expect(state.profiles[0].session?.trigger == .manual)
    }

    @Test func unknownLockTriggersDecodeAsManual() throws {
        let data = Data(#"["manual","place","teleport"]"#.utf8)
        #expect(try JSONDecoder().decode([LockTrigger].self, from: data) == [.manual, .place, .manual])
    }

    @Test func statesWithoutPlacesStillLoad() throws {
        let legacy = try JSONEncoder().encode(NagState(tasks: [NagTask(title: "Old")]))
        var object = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        object["places"] = nil
        object["placePresence"] = nil
        object["placeLinks"] = nil
        let state = try JSONDecoder().decode(NagState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(state.places.isEmpty)
        #expect(state.tasks.first?.placeTrigger == nil)
    }

    // MARK: Monitoring

    @Test func monitoringPutsLocksThenActiveNagsThenTheRestUnderTheCap() {
        let places = (0..<25).map { SavedPlace(name: String(format: "Place %02d", $0), latitude: 0, longitude: 0) }
        var done = NagTask(title: "Done", placeTrigger: PlaceTrigger(place: places[22].ref, repeats: false))
        done.completedAt = Fixture.date(28, 9)
        let state = NagState(
            tasks: [
                NagTask(title: "Active", startAt: PlaceTrigger.waitingStart, placeTrigger: PlaceTrigger(place: places[23].ref)),
                done,
            ],
            profiles: [LockProfile(name: "Lock", place: places[24].ref)],
            places: places
        )
        let monitored = PlaceMonitoring.places(for: state)
        #expect(monitored.count == 20)
        #expect(monitored.first == places[24])
        #expect(monitored[1] == places[23])
        #expect(!monitored.contains(places[22]))
        #expect(PlaceMonitoring.overflow(for: state) == 5)
    }

    @Test func monitoringFollowsLinksAndSkipsUnknownPlaces() {
        let foreign = PlaceRef(id: UUID(), name: "Office")
        var state = NagState(
            tasks: [NagTask(title: "A", placeTrigger: PlaceTrigger(place: foreign))],
            places: [home, office]
        )
        #expect(PlaceMonitoring.places(for: state, limit: 1) == [home])
        state.linkPlace(foreign, to: office.id)
        #expect(PlaceMonitoring.places(for: state, limit: 1) == [office])
        #expect(PlaceMonitoring.places(for: NagState(), limit: 20).isEmpty)
    }

    // MARK: Sync

    @Test func saveStampsTriggerChanges() {
        var state = NagState()
        var nag = state.save(placeNag(), now: Fixture.date(28, 9))
        #expect(nag.placeTriggerChangedAt == Fixture.date(28, 9))
        nag.title = "Bins out"
        nag = state.save(nag, now: Fixture.date(28, 10))
        #expect(nag.placeTriggerChangedAt == Fixture.date(28, 9))
        nag.placeTrigger = nil
        nag = state.save(nag, now: Fixture.date(28, 11))
        #expect(nag.placeTriggerChangedAt == Fixture.date(28, 11))
    }

    /// What a build without place support writes back: same nag, unknown fields gone.
    private func savedByOlderBuild(_ task: NagTask, editedAt: Date) throws -> NagTask {
        let data = try JSONEncoder().encode(task)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["placeTrigger"] = nil
        object["placeTriggerChangedAt"] = nil
        var old = try JSONDecoder().decode(NagTask.self, from: JSONSerialization.data(withJSONObject: object))
        old.title = "Edited on the old Mac"
        old.updatedAt = editedAt
        return old
    }

    @Test func olderBuildEditsDoNotDropTheTriggerInAMerge() throws {
        let nag = placeNag()
        let old = try savedByOlderBuild(nag, editedAt: Fixture.date(28, 12))
        #expect(old.placeTrigger == nil)
        let merged = TaskMerge.merge(nag, old)
        #expect(merged.title == "Edited on the old Mac")
        #expect(merged.placeTrigger == nag.placeTrigger)
        #expect(TaskMerge.merge(old, nag) == merged)
    }

    @Test func sidecarRestoresTriggersOnDevicesThatOnlySeeTheOlderCopy() throws {
        let nag = placeNag()
        let records = SyncedTasks(tasks: [nag]).placeTriggerRecords
        let old = try savedByOlderBuild(nag, editedAt: Fixture.date(28, 12))
        let restored = SyncedTasks(tasks: [old]).applyingPlaceTriggers(records)
        #expect(restored.tasks[0].placeTrigger == nag.placeTrigger)
        #expect(restored.tasks[0].title == "Edited on the old Mac")
        // And it survives the round trip through the shared iCloud blob.
        let merged = TaskMerge.merge(SyncedTasks(), restored, now: Fixture.date(28, 12))
        #expect(merged.placeTriggerRecords == records)
    }

    @Test func removingATriggerWinsOverAnOlderTrigger() {
        let stale = placeNag()
        var removed = stale
        removed.placeTrigger = nil
        removed.placeTriggerChangedAt = Fixture.date(28, 10)
        #expect(TaskMerge.merge(stale, removed).placeTrigger == nil)
        let records = SyncedTasks(tasks: [removed]).placeTriggerRecords
        #expect(SyncedTasks(tasks: [stale]).applyingPlaceTriggers(records).tasks[0].placeTrigger == nil)
    }

    @Test func olderSidecarRecordsDoNotOverrideNewerTriggers() {
        var nag = placeNag()
        nag.placeTrigger?.event = .leave
        nag.placeTriggerChangedAt = Fixture.date(28, 12)
        let stale = ["\(nag.id.uuidString)": PlaceTriggerRecord(trigger: nil, changedAt: Fixture.date(28, 8))]
        #expect(SyncedTasks(tasks: [nag]).applyingPlaceTriggers(stale).tasks[0].placeTrigger?.event == .leave)
    }

    @Test func arrivalAfterAnOlderBuildsCompletionKeepsNagging() throws {
        var phone = placeNag()
        phone.startForPlace(at: Fixture.date(28, 9))
        var mac = try savedByOlderBuild(phone, editedAt: Fixture.date(28, 10))
        mac.title = phone.title
        mac.complete(at: Fixture.date(28, 10), calendar: calendar)
        #expect(mac.completedAt != nil)

        var next = phone
        next.completedAt = nil
        next.lastCompletedAt = nil
        next.startAt = Fixture.date(28, 18)
        next.updatedAt = Fixture.date(28, 18)
        let merged = TaskMerge.merge(next, mac)
        #expect(merged.completedAt == nil)
        #expect(merged.startAt == Fixture.date(28, 18))
        #expect(merged.lastCompletedAt == Fixture.date(28, 10))
    }

    @Test func olderBuildsDecodePlaceNagsAsNotDue() throws {
        // Older builds read `startAt` as-is. A waiting place nag must look like a far-future one-off.
        let data = try JSONEncoder().encode(placeNag())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["repeatRule"] as? String == "never")
        let decoded = try JSONDecoder().decode(NagTask.self, from: data)
        #expect(decoded.startAt == PlaceTrigger.waitingStart)
        #expect(!decoded.isOutstanding(at: Fixture.date(28, 12)))
    }

    @Test func duplicatesKeepThePlaceTrigger() {
        let copy = placeNag().duplicate(now: Fixture.date(28, 9))
        #expect(copy.placeTrigger?.place == home.ref)
        #expect(copy.isAwaitingPlace)
    }
}
