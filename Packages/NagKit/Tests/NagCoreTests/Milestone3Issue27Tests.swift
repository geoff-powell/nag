import Foundation
import Testing
@testable import NagCore

@Suite struct Milestone3Issue27Tests {
    let calendar = Fixture.calendar
    let now = Fixture.date(28, 12)

    private func task(_ title: String, at date: Date? = nil, repeatRule: RepeatRule = .never) -> NagTask {
        NagTask(title: title, startAt: date ?? Fixture.date(28, 8), repeatRule: repeatRule, now: Fixture.date(28, 7))
    }

    private func item(
        _ status: BuddyItem.Status,
        kind: BuddyItem.Kind = .nag,
        dueAt: Date? = Fixture.date(28, 8),
        lastDoneAt: Date? = nil
    ) -> BuddyItem {
        BuddyItem(id: UUID(), kind: kind, title: "Item", status: status, dueAt: dueAt, lastDoneAt: lastDoneAt)
    }

    private func sharingState(_ tasks: [NagTask], profiles: [LockProfile] = [], shared: [UUID]) -> NagState {
        var state = NagState(tasks: tasks, profiles: profiles)
        state.buddy.sharingEnabled = true
        state.buddy.shared = BuddySharedItems(ids: Set(shared), updatedAt: Fixture.date(28, 7))
        return state
    }

    // MARK: - Mapping

    @Test func dueNagReadsAsStillDue() {
        let nag = task("Take meds")
        let item = BuddyItem(task: nag, now: now, calendar: calendar)
        #expect(item.status == .due)
        #expect(item.dueAt == nag.startAt)
        #expect(item.statusLabel(at: now) == "Still due")
    }

    @Test func startedNagReadsAsStarted() {
        var nag = task("Write report")
        nag.start(at: Fixture.date(28, 11))
        #expect(BuddyItem(task: nag, now: now, calendar: calendar).status == .started)
    }

    @Test func finishedOneOffReadsAsDidIt() {
        var nag = task("File taxes")
        nag.complete(at: Fixture.date(28, 9), calendar: calendar)
        let item = BuddyItem(task: nag, now: now, calendar: calendar)
        #expect(item.status == .done)
        #expect(item.dueAt == nil)
        #expect(item.lastDoneAt == Fixture.date(28, 9))
        #expect(item.statusLabel(at: now) == "Did it")
    }

    @Test func repeatingNagDoneTodayReadsAsDidItUntilTheNextOccurrence() {
        var nag = task("Stretch", repeatRule: .daily)
        nag.complete(at: Fixture.date(28, 9), calendar: calendar)
        let item = BuddyItem(task: nag, now: now, calendar: calendar)
        #expect(item.status == .done)
        #expect(item.dueAt == Fixture.date(29, 8))
        #expect(item.displayStatus(at: Fixture.date(29, 7)) == .done)
        #expect(item.displayStatus(at: Fixture.date(29, 8)) == .due)
    }

    @Test func futureNagReadsAsNotDueYetThenDueOnceItsStartPasses() {
        let item = BuddyItem(task: task("Water plants", at: Fixture.date(28, 15)), now: now, calendar: calendar)
        #expect(item.status == .upcoming)
        #expect(item.statusLabel(at: now) == "Not due yet")
        #expect(item.statusLabel(at: Fixture.date(28, 15)) == "Still due")
    }

    @Test func locksReadAsLockedUnlockedOrOff() {
        var lock = LockProfile(name: "Social")
        #expect(BuddyItem(profile: lock).statusLabel(at: now) == "Off")
        lock.lock(at: now)
        #expect(BuddyItem(profile: lock).statusLabel(at: now) == "Locked")
        lock.status = .unlocked(LockSession(startedAt: now), until: Fixture.date(28, 13))
        #expect(BuddyItem(profile: lock).statusLabel(at: now) == "Unlocked")
        #expect(BuddyItem(profile: lock).kind == .lock)
    }

    // MARK: - Privacy

    @Test func payloadCarriesOnlyTheSharedFields() throws {
        var nag = task("Take meds")
        nag.notes = "Private note"
        nag.source = "Calendar"
        nag.externalID = "secret-id"
        nag.link = URL(string: "https://example.com/private")
        nag.proof = .scanKey(UUID())
        let payload = BuddyItem(task: nag, now: now, calendar: calendar).payload()
        let object = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(Set(object.keys).isSubset(of: ["id", "kind", "title", "status", "dueAt", "lastDoneAt"]))
        let text = String(decoding: payload, as: UTF8.self)
        for secret in ["Private note", "Calendar", "secret-id", "example.com"] {
            #expect(!text.contains(secret))
        }
    }

    @Test func lockPayloadLeavesOutTheAppSelectionAndRequirements() {
        let lock = LockProfile(
            name: "Games",
            selection: Data("selected-apps".utf8),
            requirements: [UnlockRequirement(kind: .typePhrase("secret phrase"))],
            message: "private message"
        )
        let text = String(decoding: BuddyItem(profile: lock).payload(), as: UTF8.self)
        #expect(!text.contains("secret phrase"))
        #expect(!text.contains("private message"))
        #expect(!text.contains(Data("selected-apps".utf8).base64EncodedString()))
    }

    @Test func longTitlesAreCut() {
        let long = String(repeating: "a", count: 500)
        #expect(BuddyItem(task: task(long), now: now, calendar: calendar).title.count == BuddyItem.maxTitleLength)
        let decoded = BuddyItem.decode(Data(#"{"id":"\#(UUID().uuidString)","kind":"nag","title":"\#(long)","status":"due"}"#.utf8))
        #expect(decoded?.title.count == BuddyItem.maxTitleLength)
    }

    @Test func payloadRoundTrips() {
        let original = BuddyItem(task: task("Take meds"), now: now, calendar: calendar)
        #expect(BuddyItem.decode(original.payload()) == original)
    }

    @Test func unknownStatusOrKindFromANewerBuildStillDecodes() {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","kind":"habit","title":"Run","status":"paused","extra":1}"#
        let decoded = BuddyItem.decode(Data(json.utf8))
        #expect(decoded?.id == id)
        #expect(decoded?.kind == .nag)
        #expect(decoded?.status == .upcoming)
    }

    // MARK: - What's shared

    @Test func onlyChosenItemsAreShared() {
        let meds = task("Take meds")
        let plants = task("Water plants")
        let lock = LockProfile(name: "Social")
        let state = sharingState([meds, plants], profiles: [lock], shared: [meds.id, lock.id])
        let items = BuddyPlanner.items(for: state, now: now, calendar: calendar)
        #expect(Set(items.map(\.id)) == [meds.id, lock.id])
    }

    @Test func nothingIsSharedWhileSharingIsOff() {
        let meds = task("Take meds")
        var state = sharingState([meds], shared: [meds.id])
        state.buddy.sharingEnabled = false
        #expect(BuddyPlanner.items(for: state, now: now, calendar: calendar).isEmpty)
    }

    @Test func changesUpsertOnlyWhatDiffers() {
        let same = item(.due)
        var changed = item(.due)
        let fresh = item(.upcoming)
        let remoteChanged = changed
        changed.status = .done
        let changes = BuddyPlanner.changes(
            desired: [same, changed, fresh],
            remote: [same, remoteChanged],
            sharedIDs: [same.id, changed.id, fresh.id],
            deletedTaskIDs: []
        )
        #expect(changes.upserts.map(\.id) == [changed.id, fresh.id])
        #expect(changes.deletions.isEmpty)
    }

    @Test func unsharingOrDeletingAnItemDeletesItsRecord() {
        let unshared = item(.due)
        let deleted = item(.due)
        let otherDeviceLock = item(.due, kind: .lock)
        let changes = BuddyPlanner.changes(
            desired: [],
            remote: [unshared, deleted, otherDeviceLock],
            sharedIDs: [deleted.id, otherDeviceLock.id],
            deletedTaskIDs: [deleted.id]
        )
        #expect(Set(changes.deletions) == [unshared.id, deleted.id])
    }

    @Test func pruningDropsDeletedNagsFromTheSharedSet() {
        let meds = task("Take meds")
        var state = sharingState([meds], shared: [meds.id])
        state.deleteTask(meds.id, at: now)
        let pruned = state.pruneDeletedBuddyItems(at: now)
        #expect(pruned)
        #expect(state.buddy.shared.ids.isEmpty)
        #expect(state.buddy.shared.updatedAt == now)
        let prunedAgain = state.pruneDeletedBuddyItems(at: now)
        #expect(!prunedAgain)
    }

    // MARK: - Sync compatibility

    @Test func sharedSetMergesLastWriterWins() {
        let a = BuddySharedItems(ids: [UUID()], updatedAt: Fixture.date(28, 9))
        let b = BuddySharedItems(ids: [UUID()], updatedAt: Fixture.date(28, 10))
        #expect(BuddySharedItems.merge(a, b) == b)
        #expect(BuddySharedItems.merge(b, a) == b)
    }

    @Test func sharedSetTieTakesTheUnion() {
        let a = BuddySharedItems(ids: [UUID()], updatedAt: Fixture.date(28, 9))
        let b = BuddySharedItems(ids: [UUID()], updatedAt: Fixture.date(28, 9))
        #expect(BuddySharedItems.merge(a, b).ids == a.ids.union(b.ids))
        #expect(BuddySharedItems.merge(a, b) == BuddySharedItems.merge(b, a))
    }

    @Test func setSharedStampsOnlyRealChanges() {
        var settings = BuddySettings()
        let id = UUID()
        settings.setShared(id, false, at: now)
        #expect(settings.shared.updatedAt == .distantPast)
        settings.setShared(id, true, at: now)
        #expect(settings.isShared(id))
        #expect(settings.shared.updatedAt == now)
    }

    @Test func stateSavedBeforeBuddyExistedStillLoads() throws {
        let json = #"{"tasks":[],"profiles":[],"keys":[],"deletedTasks":{}}"#
        let state = try JSONDecoder().decode(NagState.self, from: Data(json.utf8))
        #expect(state.buddy == BuddySettings())
        #expect(!state.buddy.usesCloudKit)
    }

    @Test func sharingANagLeavesItsSyncedPayloadUnchanged() {
        let meds = task("Take meds")
        var state = NagState(tasks: [meds])
        let before = state.syncedTasks
        state.buddy.setShared(meds.id, true, at: now)
        #expect(state.syncedTasks == before)
        #expect(state.task(meds.id) == meds)
    }

    // MARK: - Nudge limits (buddy side)

    @Test func canNudgeSomethingStillDue() {
        #expect(BuddyNudgeRule.canNudge(item(.due), lastSentAt: nil, now: now))
    }

    @Test func cantNudgeSomethingDoneStartedOrNotDue() {
        #expect(!BuddyNudgeRule.canNudge(item(.done, dueAt: nil), lastSentAt: nil, now: now))
        #expect(!BuddyNudgeRule.canNudge(item(.started), lastSentAt: nil, now: now))
        #expect(!BuddyNudgeRule.canNudge(item(.upcoming, dueAt: Fixture.date(28, 15)), lastSentAt: nil, now: now))
        #expect(!BuddyNudgeRule.canNudge(item(.upcoming, kind: .lock, dueAt: nil), lastSentAt: nil, now: now))
    }

    @Test func oneNudgePerItemUntilTheCooldownPasses() {
        let due = item(.due)
        let sent = Fixture.date(28, 11)
        #expect(!BuddyNudgeRule.canNudge(due, lastSentAt: sent, now: now))
        #expect(BuddyNudgeRule.nextNudgeAt(for: due, lastSentAt: sent, now: now) == Fixture.date(28, 15))
        #expect(BuddyNudgeRule.canNudge(due, lastSentAt: sent, now: Fixture.date(28, 15)))
    }

    @Test func doingItResetsTheNudgeLimit() {
        let sent = Fixture.date(28, 11)
        let doneSince = item(.due, dueAt: Fixture.date(28, 11, 30), lastDoneAt: Fixture.date(28, 11, 15))
        #expect(BuddyNudgeRule.canNudge(doneSince, lastSentAt: sent, now: now))
    }

    // MARK: - Nudge delivery (owner side)

    @Test func nudgeAboutSomethingDueIsDeliveredAndConsumed() {
        let due = item(.due)
        let nudge = BuddyNudge(itemID: due.id, from: "Sam", sentAt: Fixture.date(28, 11, 50))
        let delivery = BuddyNudgeInbox.process([nudge], items: [due], lastDelivered: [:], now: now)
        #expect(delivery.notices.count == 1)
        #expect(delivery.notices.first?.title == "Sam sent you a nudge")
        #expect(delivery.notices.first?.body.contains("Item") == true)
        #expect(delivery.consumed == [nudge.id])
        #expect(delivery.lastDelivered[due.id.uuidString] == now)
    }

    @Test func nudgesWithoutANameUseAGentleDefault() {
        let due = item(.due)
        let delivery = BuddyNudgeInbox.process([BuddyNudge(itemID: due.id, from: "  ", sentAt: now)], items: [due], lastDelivered: [:], now: now)
        #expect(delivery.notices.first?.title == "Your buddy sent you a nudge")
    }

    @Test func repeatedNudgesProduceOneNotification() {
        let due = item(.due)
        let nudges = (0..<5).map { BuddyNudge(itemID: due.id, from: "Sam", sentAt: Fixture.date(28, 11, $0)) }
        let delivery = BuddyNudgeInbox.process(nudges, items: [due], lastDelivered: [:], now: now)
        #expect(delivery.notices.count == 1)
        #expect(delivery.consumed.count == 5)
    }

    @Test func ownerEnforcesTheCooldownEvenIfTheBuddysAppDoesnt() {
        let due = item(.due)
        let nudge = BuddyNudge(itemID: due.id, from: "Sam", sentAt: now)
        let delivery = BuddyNudgeInbox.process(
            [nudge],
            items: [due],
            lastDelivered: [due.id.uuidString: Fixture.date(28, 10)],
            now: now
        )
        #expect(delivery.notices.isEmpty)
        #expect(delivery.consumed == [nudge.id])
    }

    @Test func nudgesForUnsharedDoneOrStaleItemsAreDroppedQuietly() {
        let done = item(.done, dueAt: nil)
        let due = item(.due)
        let nudges = [
            BuddyNudge(itemID: UUID(), from: "Sam", sentAt: now),
            BuddyNudge(itemID: done.id, from: "Sam", sentAt: now),
            BuddyNudge(itemID: due.id, from: "Sam", sentAt: Fixture.date(27, 11)),
        ]
        let delivery = BuddyNudgeInbox.process(nudges, items: [done, due], lastDelivered: [:], now: now)
        #expect(delivery.notices.isEmpty)
        #expect(delivery.consumed.count == 3)
    }

    @Test func deliveryHistoryForgetsItemsNoLongerShared() {
        let due = item(.due)
        let delivery = BuddyNudgeInbox.process([], items: [due], lastDelivered: [UUID().uuidString: now, due.id.uuidString: now], now: now)
        #expect(Set(delivery.lastDelivered.keys) == [due.id.uuidString])
    }

    @Test func nudgeNamesAreCut() {
        let nudge = BuddyNudge(itemID: UUID(), from: String(repeating: "n", count: 200), sentAt: now)
        #expect(nudge.from.count == BuddyNudge.maxNameLength)
        #expect(BuddyNudge.decode(nudge.payload()) == nudge)
    }
}
