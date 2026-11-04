import CoreLocation
import Foundation
import NagCore
@preconcurrency import UserNotifications

/// Watches saved places with `CLMonitor` and feeds arrivals and departures into the shared state.
///
/// Used by both apps. iOS keeps monitoring with Nag closed and relaunches it in the background when a
/// place is entered or left, as long as a `PlaceMonitor` is started early in launch. macOS only monitors
/// while Nag is running. Either way, monitoring resumes only after the first unlock following a restart.
/// Nothing runs until location access is granted, so the feature stays dormant for anyone who never
/// adds a place.
@MainActor
public final class PlaceMonitor: NSObject {
    public static let monitorName = "nag.places"

    public private(set) var authorization: CLAuthorizationStatus
    /// Called after location access changes.
    public var onAuthorizationChange: (() -> Void)?

    private let store: SharedStore
    /// Called after an arrival or departure was written to the store, with the nags it started.
    private let onEvent: (_ started: [UUID]) -> Void
    private let manager = CLLocationManager()
    private var monitor: CLMonitor?
    private var opening: Task<CLMonitor, Never>?
    private var eventsTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    public init(store: SharedStore, onEvent: @escaping (_ started: [UUID]) -> Void) {
        self.store = store
        self.onEvent = onEvent
        self.authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    /// Location access allows monitoring. "While Using" works while Nag is open; "Always" also works with
    /// Nag in the background, and on iOS lets an arrival relaunch it.
    public var canMonitor: Bool {
        #if os(iOS)
        authorization == .authorizedAlways || authorization == .authorizedWhenInUse
        #else
        authorization == .authorizedAlways
        #endif
    }

    public var hasAlwaysAccess: Bool { authorization == .authorizedAlways }

    /// Opens the monitor and starts listening, if location access was granted. Call early in launch so
    /// an event that relaunched the app is delivered.
    public func start() {
        guard canMonitor else { return }
        refresh(state: store.load())
    }

    /// Monitors the places `PlaceMonitoring` picks for `state`, and stops monitoring the rest.
    public func refresh(state: NagState) {
        guard canMonitor else { return }
        let wanted = Dictionary(
            PlaceMonitoring.places(for: state).map { (Self.identifier(for: $0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let previous = refreshTask
        refreshTask = Task {
            await previous?.value
            let monitor = await openMonitor()
            let current = Set(await monitor.identifiers)
            for identifier in current where wanted[identifier] == nil {
                await monitor.remove(identifier)
            }
            for (identifier, place) in wanted where !current.contains(identifier) {
                let condition = CLMonitor.CircularGeographicCondition(
                    center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
                    radius: place.radius
                )
                await monitor.add(condition, identifier: identifier, assuming: .unknown)
            }
        }
    }

    public func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }

    /// Asks to upgrade to "Always", so places work with Nag closed.
    public func requestAlways() {
        manager.requestAlwaysAuthorization()
    }

    /// One fix of where the device is now, or `nil` if none arrives within `timeout`.
    public func currentCoordinate(timeout: Duration = .seconds(15)) async -> CLLocationCoordinate2D? {
        await withTaskGroup(of: CLLocationCoordinate2D?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let location = update.location { return location.coordinate }
                    }
                } catch {}
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - Private

    /// Identifiers include the geometry, so moving or resizing a place re-adds its condition.
    static func identifier(for place: SavedPlace) -> String {
        String(format: "%@|%.5f|%.5f|%.0f", place.id.uuidString, place.latitude, place.longitude, place.radius)
    }

    static func placeID(in identifier: String) -> UUID? {
        identifier.split(separator: "|").first.flatMap { UUID(uuidString: String($0)) }
    }

    private func openMonitor() async -> CLMonitor {
        if let monitor { return monitor }
        if let opening { return await opening.value }
        let task = Task { await CLMonitor(Self.monitorName) }
        opening = task
        let monitor = await task.value
        self.monitor = monitor
        opening = nil
        listen(to: monitor)
        return monitor
    }

    private func listen(to monitor: CLMonitor) {
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            do {
                for try await event in await monitor.events {
                    self?.handle(identifier: event.identifier, state: event.state, date: event.date)
                }
            } catch {
                NagLog.error("Place monitoring stopped: \(error)")
            }
        }
    }

    private func handle(identifier: String, state: CLMonitor.Event.State, date: Date) {
        guard let placeID = Self.placeID(in: identifier) else { return }
        let inside: Bool
        switch state {
        case .satisfied: inside = true
        case .unsatisfied: inside = false
        default: return
        }
        let now = min(date, .now)
        let started = store.update { $0.applyPlaceObservation(placeID: placeID, inside: inside, now: now) }
        onEvent(started)
    }

    private func authorizationChanged(_ status: CLAuthorizationStatus) {
        guard status != authorization else { return }
        authorization = status
        if canMonitor { start() }
        onAuthorizationChange?()
    }
}

extension PlaceMonitor: CLLocationManagerDelegate {
    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorizationChanged(status) }
    }
}

extension NotificationSync {
    /// Nags right away about a nag a place just started. The repeating nag that follows waits one
    /// interval, so without this the first nag would come late.
    public static func nagNow(_ task: NagTask, placeName: String) async {
        guard let trigger = task.placeTrigger else { return }
        let content = UNMutableNotificationContent()
        content.title = task.title
        content.body = switch trigger.event {
        case .arrive: task.notes.isEmpty ? "You're at \(placeName). Do it now." : task.notes
        case .leave: task.notes.isEmpty ? "You've left \(placeName). Do it now." : task.notes
        }
        content.sound = .default
        content.categoryIdentifier = NagID.Category.forTask(task, canSnooze: (task.snoozesLeft ?? 1) > 0)
        content.threadIdentifier = task.id.uuidString
        content.userInfo = [NagID.UserInfo.taskID: task.id.uuidString]
        content.interruptionLevel = task.style.breakThroughFocus ? .timeSensitive : .active
        // The "nag|" prefix lets the usual clean-up remove it once the nag is done.
        let identifier = "\(NagID.nagNotificationPrefix)\(task.id.uuidString)|place|\(Int(task.startAt.timeIntervalSince1970))"
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        )
    }
}
