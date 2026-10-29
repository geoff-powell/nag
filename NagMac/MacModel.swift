import Foundation
import NagKit
import Observation
import ServiceManagement
@preconcurrency import UserNotifications

struct PresentedID: Identifiable, Hashable {
    let id: UUID
}

/// The Mac app's source of truth. Same shape as the iPhone's AppModel, plus a tick that does what
/// DeviceActivity does on iOS: run schedules, expire timed unlocks, and auto-lock while nags are due.
@MainActor
@Observable
final class MacModel {
    enum Section: Hashable {
        case nags
        case locks
        case settings
    }

    let store: SharedStore
    private(set) var state: NagState
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    var section: Section = .nags
    var unlockRequest: PresentedID?

    var calendar: Calendar { .current }

    /// Called after every state change and tick, to re-apply blocking and panels.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var openMainWindow: (() -> Void)?

    @ObservationIgnored private var changeObservation: SharedStore.ChangeObservation?
    @ObservationIgnored private var cloudSync: CloudTaskSync?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var notificationTask: Task<Void, Never>?
    @ObservationIgnored private var lastNotificationSync = Date.distantPast

    static let tickInterval: Duration = .seconds(15)

    init(store: SharedStore) {
        self.store = store
        self.state = store.load()
    }

    func start() {
        changeObservation = store.observeChanges { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        let cloud = CloudTaskSync(store: store) { [weak self] in
            Task { @MainActor in
                self?.reload()
                self?.syncNotifications()
            }
        }
        cloudSync = cloud
        cloud.start()

        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
        Task { await refreshPermissions() }
    }

    /// Brings locks up to date, then re-enforces. Notifications are re-planned at least once a minute
    /// so escalation and quiet hours stay current.
    func tick(now: Date = .now) {
        var autoUnlocked: [LockProfile] = []
        let updated = store.update { state in
            autoUnlocked = LockMaintenance.run(&state, now: now, calendar: calendar)
            return state
        }
        let changed = updated != state
        state = updated
        onChange?()

        for profile in autoUnlocked {
            Task {
                await NotificationSync.alert(title: "\(profile.name) unlocked", body: Self.unlockedMessage(for: profile), profileID: profile.id)
            }
        }
        if changed || now.timeIntervalSince(lastNotificationSync) >= 60 {
            syncNotifications()
        }
    }

    func reload() {
        state = store.load()
        onChange?()
    }

    func update(_ change: (inout NagState) -> Void) {
        state = store.update { state in
            change(&state)
            return state
        }
        cloudSync?.reconcile()
        tick()
        syncNotifications()
    }

    /// Re-plans notifications, after any earlier sync finishes so they never overlap.
    func syncNotifications() {
        lastNotificationSync = .now
        let previous = notificationTask
        let store = store
        let calendar = calendar
        notificationTask = Task {
            await previous?.value
            let state = store.load()
            let now = Date()
            let planner = NagPlanner(allowRepeating: !state.settings.quietHours.isActive, calendar: calendar)
            let plan = planner.plan(tasks: state.tasks, quietHours: state.settings.quietHours, now: now)
            await NotificationSync.apply(plan, tasks: state.tasks, now: now)
        }
    }

    func waitForNotificationSync() async {
        await notificationTask?.value
    }

    static func unlockedMessage(for profile: LockProfile) -> String {
        if let until = profile.unlockedUntil {
            return "Nice work. Your apps are open until \(until.formatted(date: .omitted, time: .shortened))."
        }
        return "Nice work. Everything's done, so your apps are open."
    }

    // MARK: - Navigation

    func showUnlock(_ profileID: UUID) {
        section = .locks
        unlockRequest = PresentedID(id: profileID)
        openMainWindow?()
    }

    func show(_ section: Section) {
        self.section = section
        openMainWindow?()
    }

    // MARK: - Nags

    func dueCount(at now: Date) -> Int {
        state.tasks.filter { $0.isOutstanding(at: now) }.count
    }

    /// Keys live on the iPhone, so nags that need a scan can only be finished there.
    func needsPhoneScan(_ task: NagTask) -> Bool {
        task.proof.keyID != nil
    }

    func saveTask(_ task: NagTask) {
        var task = task
        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        task.updatedAt = .now
        update { state in
            if let index = state.tasks.firstIndex(where: { $0.id == task.id }) {
                if state.tasks[index].startAt != task.startAt {
                    task.snoozedUntil = nil
                    task.snoozeCount = 0
                }
                state.tasks[index] = task
            } else {
                state.tasks.append(task)
            }
        }
    }

    func quickAdd(_ title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        saveTask(NagTask(title: title))
    }

    func duplicateTask(_ id: UUID) {
        guard let task = state.task(id) else { return }
        saveTask(task.duplicate(now: .now))
    }

    func canDeleteTask(_ id: UUID) -> Bool {
        !state.isTaskRequiredByEngagedLock(id)
    }

    func deleteTask(_ id: UUID) {
        guard canDeleteTask(id) else { return }
        update { $0.deleteTask(id, at: .now) }
    }

    func complete(_ id: UUID) {
        guard let task = state.task(id), !needsPhoneScan(task) else { return }
        mutateTask(id) { $0.complete(at: .now, calendar: calendar) }
    }

    func snooze(_ id: UUID) {
        mutateTask(id) { _ = $0.snooze(at: .now) }
    }

    func reopen(_ id: UUID) {
        mutateTask(id) { $0.reopen(at: .now) }
    }

    func clearFinished() {
        let finished = state.tasks.filter { $0.isFinished && canDeleteTask($0.id) }.map(\.id)
        guard !finished.isEmpty else { return }
        update { state in
            for id in finished { state.deleteTask(id, at: .now) }
        }
    }

    private func mutateTask(_ id: UUID, _ change: (inout NagTask) -> Void) {
        update { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { return }
            change(&state.tasks[index])
        }
    }

    // MARK: - Locks

    var strictEngagedLock: LockProfile? {
        state.profiles.first { $0.isEngaged && $0.strict }
    }

    func profile(_ id: UUID) -> LockProfile? {
        state.profile(id)
    }

    func evaluate(_ profile: LockProfile, now: Date) -> [RequirementStatus] {
        UnlockEvaluator.evaluate(profile, state: state, steps: nil, now: now, calendar: calendar)
    }

    /// Saves a lock's settings without changing whether it's locked.
    func saveProfile(_ profile: LockProfile) {
        update { state in
            if let index = state.profiles.firstIndex(where: { $0.id == profile.id }) {
                var updated = profile
                updated.status = state.profiles[index].status
                updated.lastScheduledLockAt = state.profiles[index].lastScheduledLockAt
                updated.autoLockPausedUntil = state.profiles[index].autoLockPausedUntil
                state.profiles[index] = updated
            } else {
                state.profiles.append(profile)
            }
        }
    }

    func deleteProfile(_ id: UUID) {
        guard state.profile(id)?.isEngaged == false else { return }
        update { $0.profiles.removeAll { $0.id == id } }
    }

    func lockNow(_ id: UUID) {
        mutateProfile(id) { $0.lock(at: .now) }
    }

    func startWaitTimer(_ id: UUID) {
        mutateProfile(id) { $0.requestUnlock(at: .now) }
    }

    func recordProof(profileID: UUID, requirementID: UUID) {
        mutateProfile(profileID) { $0.recordProof(requirementID) }
    }

    @discardableResult
    func unlock(_ id: UUID) -> Bool {
        guard let profile = state.profile(id), profile.isLocked,
              UnlockEvaluator.allMet(profile, state: state, steps: nil, now: .now, calendar: calendar)
        else { return false }
        mutateProfile(id) { $0.grantUnlock(at: .now) }
        return true
    }

    func relockNow(_ id: UUID) {
        mutateProfile(id) { $0.relockNow(at: .now) }
    }

    var emergencyUnlocksLeft: Int {
        state.emergencyUnlocksLeft(at: .now, calendar: calendar)
    }

    func emergencyUnlock(_ id: UUID) {
        guard emergencyUnlocksLeft > 0, state.profile(id)?.isEngaged == true else { return }
        update { state in
            guard let index = state.profiles.firstIndex(where: { $0.id == id }) else { return }
            state.profiles[index].emergencyUnlock(at: .now)
            state.settings.emergencyUnlocksUsed.append(.now)
        }
    }

    private func mutateProfile(_ id: UUID, _ change: (inout LockProfile) -> Void) {
        update { state in
            guard let index = state.profiles.firstIndex(where: { $0.id == id }) else { return }
            change(&state.profiles[index])
        }
    }

    // MARK: - Settings

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        update { change(&$0.settings) }
    }

    var hasLaunchedBefore: Bool {
        UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
    }

    func markLaunched() {
        UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
    }

    func refreshPermissions() async {
        notificationStatus = await NotificationSync.authorizationStatus()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func requestNotifications() async {
        _ = await NotificationSync.requestAuthorization()
        await refreshPermissions()
        syncNotifications()
    }

    /// Returns an error message if the change didn't take.
    func setLaunchAtLogin(_ enabled: Bool) -> String? {
        defer { launchAtLogin = SMAppService.mainApp.status == .enabled }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
