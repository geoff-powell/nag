import Foundation
import Testing
@testable import NagCore

@Suite struct Milestone3Issue21Tests {
    let calendar = Fixture.calendar
    let now = Fixture.date(28, 12)

    private func mac(
        _ activity: DeviceHeartbeat.Activity = .active,
        updatedAt: Date? = nil,
        activeUntil: Date? = nil,
        id: String = "mac"
    ) -> DeviceHeartbeat {
        let updatedAt = updatedAt ?? now
        return DeviceHeartbeat(
            deviceID: id,
            platform: .mac,
            activity: activity,
            updatedAt: updatedAt,
            activeUntil: activeUntil ?? updatedAt.addingTimeInterval(DeviceHandoff.activeValidity)
        )
    }

    private func planner() -> NagPlanner { NagPlanner(calendar: calendar) }

    private func dueTask(_ title: String = "Due", escalation: Escalation = .steady, interval: Int = 5) -> NagTask {
        NagTask(
            title: title,
            startAt: Fixture.date(28, 11),
            style: NagStyle(intervalMinutes: interval, escalation: escalation),
            now: Fixture.date(28, 7)
        )
    }

    private func oneOffDates(_ plan: NagPlan) -> [Date] {
        plan.notifications.compactMap {
            if case .at(let date) = $0.trigger { return date }
            return nil
        }
    }

    private func hasRepeating(_ plan: NagPlan) -> Bool {
        plan.notifications.contains {
            if case .every = $0.trigger { return true }
            return false
        }
    }

    // MARK: - Reading heartbeats

    @Test func noHeartbeatMeansFullNagging() {
        #expect(DeviceHandoff.handoffUntil(heartbeats: [], now: now) == nil)
    }

    @Test func freshActiveMacHandsOffUntilItsActiveUntil() {
        let until = now.addingTimeInterval(10 * 60)
        #expect(DeviceHandoff.handoffUntil(heartbeats: [mac(activeUntil: until)], now: now) == until)
    }

    @Test func expiredHeartbeatMeansFullNagging() {
        let old = mac(updatedAt: now.addingTimeInterval(-20 * 60))
        #expect(DeviceHandoff.handoffUntil(heartbeats: [old], now: now) == nil)
        let endsNow = mac(activeUntil: now)
        #expect(DeviceHandoff.handoffUntil(heartbeats: [endsNow], now: now) == nil)
    }

    @Test func idleMacMeansFullNagging() {
        #expect(DeviceHandoff.handoffUntil(heartbeats: [mac(.idle, activeUntil: now.addingTimeInterval(600))], now: now) == nil)
    }

    @Test func iPhoneAndUnknownHeartbeatsNeverHandOff() {
        var phone = mac()
        phone.platform = .iPhone
        var unknown = mac()
        unknown.platform = .unknown
        #expect(DeviceHandoff.handoffUntil(heartbeats: [phone, unknown], now: now) == nil)
    }

    @Test func activeUntilIsCappedByWhenItWasWritten() {
        let greedy = mac(updatedAt: now.addingTimeInterval(-10 * 60), activeUntil: now.addingTimeInterval(3600))
        #expect(DeviceHandoff.handoffUntil(heartbeats: [greedy], now: now) == now.addingTimeInterval(5 * 60))
    }

    @Test func slightlyFutureTimestampsAreClampedToTheValidityFromNow() {
        let ahead = mac(updatedAt: now.addingTimeInterval(2 * 60))
        #expect(DeviceHandoff.handoffUntil(heartbeats: [ahead], now: now) == now.addingTimeInterval(DeviceHandoff.activeValidity))
    }

    @Test func farFutureTimestampsAreDistrusted() {
        let ahead = mac(updatedAt: now.addingTimeInterval(DeviceHandoff.maxClockSkew + 60))
        #expect(DeviceHandoff.handoffUntil(heartbeats: [ahead], now: now) == nil)
    }

    @Test func theLatestOfSeveralActiveMacsWins() {
        let early = mac(activeUntil: now.addingTimeInterval(300), id: "a")
        let late = mac(activeUntil: now.addingTimeInterval(600), id: "b")
        let idle = mac(.idle, id: "c")
        #expect(DeviceHandoff.handoffUntil(heartbeats: [early, idle, late], now: now) == now.addingTimeInterval(600))
    }

    @Test func unknownPlatformsDecode() throws {
        let json = #"{"deviceID":"x","platform":"vision","activity":"active","updatedAt":0,"activeUntil":60}"#
        let heartbeat = try JSONDecoder().decode(DeviceHeartbeat.self, from: Data(json.utf8))
        #expect(heartbeat.platform == .unknown)
    }

    @Test func settingsAndStateFromOlderVersionsDefaultSensibly() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(settings.deviceHandoff)
        let state = try JSONDecoder().decode(NagState.self, from: Data("{}".utf8))
        #expect(state.devices.isEmpty)
    }

    // MARK: - Planning

    @Test func withoutHandoffADueNagRepeats() {
        let plan = planner().plan(tasks: [dueTask()], quietHours: QuietHours(), now: now)
        #expect(hasRepeating(plan))
    }

    @Test func handoffReplacesRepeatingWithSparseRemindersThenFullPace() {
        let until = now.addingTimeInterval(10 * 60)
        let plan = planner().plan(tasks: [dueTask()], quietHours: QuietHours(), handoffUntil: until, now: now)
        #expect(!hasRepeating(plan))
        let dates = oneOffDates(plan)
        // Nothing before the window ends: the next 30-minute step from 11:00 is 12:30.
        #expect(dates.first == until)
        #expect(dates.allSatisfy { $0 >= until })
        // Then every 5 minutes, the nag's own pace.
        #expect(dates.prefix(3) == [until, until.addingTimeInterval(300), until.addingTimeInterval(600)])
        #expect(plan.nextWake == until)
    }

    @Test func reducedRemindersUseTheSlowIntervalAnchoredOnStart() {
        let until = now.addingTimeInterval(DeviceHandoff.activeValidity * 4)
        let plan = planner().plan(tasks: [dueTask()], quietHours: QuietHours(), handoffUntil: until, now: now)
        let reduced = oneOffDates(plan).filter { $0 < until }
        #expect(reduced == [Fixture.date(28, 12, 30)])
    }

    @Test func aFutureNagStillGetsItsDueTimeReminder() {
        let task = NagTask(title: "Later", startAt: Fixture.date(28, 12, 5), style: NagStyle(intervalMinutes: 5, escalation: .steady), now: now)
        let until = now.addingTimeInterval(15 * 60)
        let plan = planner().plan(tasks: [task], quietHours: QuietHours(), handoffUntil: until, now: now)
        let dates = oneOffDates(plan)
        #expect(dates.filter { $0 < until } == [Fixture.date(28, 12, 5)])
        // Full pace resumes exactly at the end of the window, on the nag's own curve.
        #expect(dates.filter { $0 >= until }.first == Fixture.date(28, 12, 15))
        let full = oneOffDates(planner().plan(tasks: [task], quietHours: QuietHours(), now: now))
        #expect(dates.filter { $0 >= until } == full.filter { $0 >= until })
    }

    @Test func reducedCadenceNeverNagsMoreOftenThanTheNagItself() {
        let slow = NagTask(title: "Slow", startAt: Fixture.date(28, 12, 1), style: NagStyle(intervalMinutes: 90, escalation: .steady), now: now)
        let until = now.addingTimeInterval(4 * 3600)
        let plan = planner().plan(tasks: [slow], quietHours: QuietHours(), handoffUntil: until, now: now)
        let reduced = oneOffDates(plan).filter { $0 < until }
        #expect(reduced == [Fixture.date(28, 12, 1), Fixture.date(28, 13, 31), Fixture.date(28, 15, 1)])
    }

    @Test func expiredHandoffPlansExactlyLikeNone() {
        let tasks = [dueTask(), NagTask(title: "Later", startAt: Fixture.date(28, 13), now: now)]
        let none = planner().plan(tasks: tasks, quietHours: QuietHours(), now: now)
        let past = planner().plan(tasks: tasks, quietHours: QuietHours(), handoffUntil: now, now: now)
        #expect(none == past)
    }

    @Test func replanningInsideTheWindowKeepsIdentifiers() {
        let task = NagTask(title: "Later", startAt: Fixture.date(28, 12, 5), now: now)
        let until = now.addingTimeInterval(3600)
        let first = planner().plan(tasks: [task], quietHours: QuietHours(), handoffUntil: until, now: now)
        let second = planner().plan(tasks: [task], quietHours: QuietHours(), handoffUntil: until, now: now.addingTimeInterval(60))
        #expect(Set(second.notifications.map(\.identifier)).isSubset(of: Set(first.notifications.map(\.identifier))))
    }

    @Test func escalationResumesAtTheWindowEndForADueNag() {
        let task = dueTask(escalation: .relentless, interval: 16)
        let until = now.addingTimeInterval(10 * 60)
        let plan = planner().plan(tasks: [task], quietHours: QuietHours(), handoffUntil: until, now: now)
        let dates = oneOffDates(plan)
        // 70 minutes overdue at the window end, so relentless is on its third step: 4 minutes apart.
        #expect(dates.prefix(2) == [until, until.addingTimeInterval(4 * 60)])
    }

    @Test func quietHoursStillWin() {
        let quiet = QuietHours(enabled: true, startMinute: 12 * 60 + 5, endMinute: 13 * 60)
        let until = now.addingTimeInterval(15 * 60)
        let plan = planner().plan(tasks: [dueTask()], quietHours: quiet, handoffUntil: until, now: now)
        let dates = oneOffDates(plan)
        #expect(!dates.contains { quiet.contains($0, calendar: calendar) })
        #expect(dates.first == Fixture.date(28, 13))
    }

    @Test func aLongOverdueNagStillGetsReminders() {
        var task = dueTask(escalation: .relentless, interval: 1)
        task.startAt = Fixture.date(1, 0)
        let until = now.addingTimeInterval(10 * 60)
        let plan = planner().plan(tasks: [task], quietHours: QuietHours(), handoffUntil: until, now: now)
        #expect(oneOffDates(plan).first == until)
    }

    // MARK: - Publishing

    @Test func macIsActiveOnlyWhenUnlockedAwakeRecentlyUsedAbleToNagAndEnabled() {
        func activity(
            input: TimeInterval = 10,
            locked: Bool = false,
            asleep: Bool = false,
            canNag: Bool = true,
            enabled: Bool = true
        ) -> DeviceHeartbeat.Activity {
            DeviceHandoff.macActivity(secondsSinceInput: input, screenLocked: locked, asleep: asleep, canNag: canNag, enabled: enabled)
        }
        #expect(activity() == .active)
        #expect(activity(input: DeviceHandoff.inputIdleThreshold) == .idle)
        #expect(activity(locked: true) == .idle)
        #expect(activity(asleep: true) == .idle)
        #expect(activity(canNag: false) == .idle)
        #expect(activity(enabled: false) == .idle)
    }

    @Test func activeHeartbeatsAreRefreshedOnlyEveryRefreshInterval() {
        let first = DeviceHandoff.heartbeatToPublish(previous: nil, deviceID: "mac", platform: .mac, activity: .active, now: now)
        #expect(first?.activeUntil == now.addingTimeInterval(DeviceHandoff.activeValidity))
        let soon = now.addingTimeInterval(DeviceHandoff.refreshInterval - 1)
        #expect(DeviceHandoff.heartbeatToPublish(previous: first, deviceID: "mac", platform: .mac, activity: .active, now: soon) == nil)
        let later = now.addingTimeInterval(DeviceHandoff.refreshInterval)
        #expect(DeviceHandoff.heartbeatToPublish(previous: first, deviceID: "mac", platform: .mac, activity: .active, now: later)?.updatedAt == later)
    }

    @Test func goingIdleIsPublishedOnceAndImmediately() {
        let active = DeviceHandoff.heartbeatToPublish(previous: nil, deviceID: "mac", platform: .mac, activity: .active, now: now)
        let idle = DeviceHandoff.heartbeatToPublish(previous: active, deviceID: "mac", platform: .mac, activity: .idle, now: now.addingTimeInterval(1))
        #expect(idle?.activity == .idle)
        #expect(DeviceHandoff.heartbeatToPublish(previous: idle, deviceID: "mac", platform: .mac, activity: .idle, now: now.addingTimeInterval(2)) == nil)
        #expect(DeviceHandoff.heartbeatToPublish(previous: nil, deviceID: "mac", platform: .mac, activity: .idle, now: now) == nil)
    }

    @Test func aHeartbeatFromTheFutureIsRewritten() {
        let ahead = mac(updatedAt: now.addingTimeInterval(3600))
        #expect(DeviceHandoff.heartbeatToPublish(previous: ahead, deviceID: "mac", platform: .mac, activity: .active, now: now)?.updatedAt == now)
    }

    @Test func mergingKeepsOtherDevicesAndPrunesStaleOnes() {
        let phone = DeviceHeartbeat(deviceID: "phone", platform: .iPhone, activity: .idle, updatedAt: now, activeUntil: now)
        let gone = mac(.idle, updatedAt: now.addingTimeInterval(-DeviceHandoff.pruneAfter), id: "old")
        let merged = DeviceHandoff.merging(mac(), into: ["phone": phone, "old": gone, "mac": mac(.idle)], now: now)
        #expect(Set(merged.keys) == ["phone", "mac"])
        #expect(merged["mac"]?.activity == .active)
    }
}
