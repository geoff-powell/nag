import Foundation

// MARK: - Models

/// A place saved on this device, such as Home or the shop. Places are never synced: nags and locks that
/// mention one carry a `PlaceRef` with its ID and name, and other devices show the name only.
public struct SavedPlace: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var latitude: Double
    public var longitude: Double
    /// Meters. Clamped to `SavedPlace.radiusRange`.
    public var radius: Double

    public static let radiusRange: ClosedRange<Double> = 50...1000
    public static let defaultRadius: Double = 150

    public init(id: UUID = UUID(), name: String, latitude: Double, longitude: Double, radius: Double = SavedPlace.defaultRadius) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radius = min(max(radius, Self.radiusRange.lowerBound), Self.radiusRange.upperBound)
    }

    public var ref: PlaceRef { PlaceRef(id: id, name: name) }
}

/// A place mentioned by a nag or lock. The name is kept so devices without the place can still show it.
public struct PlaceRef: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public enum PlaceEvent: String, Codable, CaseIterable, Sendable {
    case arrive
    case leave

    public func label(_ placeName: String) -> String {
        switch self {
        case .arrive: "When I arrive at \(placeName)"
        case .leave: "When I leave \(placeName)"
        }
    }

    public func shortLabel(_ placeName: String) -> String {
        switch self {
        case .arrive: "Arrive at \(placeName)"
        case .leave: "Leave \(placeName)"
        }
    }
}

/// Starts a nag when you arrive at or leave a place.
public struct PlaceTrigger: Codable, Hashable, Sendable {
    public var place: PlaceRef
    public var event: PlaceEvent
    /// Nag again on every arrival (or departure) after it's been done. Otherwise it's a one-off.
    public var repeats: Bool

    /// `startAt` while a place nag waits for its place. Far enough out that builds without place
    /// support treat the nag as upcoming and never nag.
    public static let waitingStart = Date.distantFuture
    /// Anything at or past this counts as waiting, so rounding through JSON can't matter.
    public static let waitingThreshold = Date(timeIntervalSinceReferenceDate: 30_000_000_000)

    public init(place: PlaceRef, event: PlaceEvent = .arrive, repeats: Bool = true) {
        self.place = place
        self.event = event
        self.repeats = repeats
    }
}

/// Whether this device is at a place, and since when.
public struct PlacePresence: Codable, Hashable, Sendable {
    public var inside: Bool
    public var since: Date

    public init(inside: Bool, since: Date) {
        self.inside = inside
        self.since = since
    }
}

// MARK: - Nags

extension NagTask {
    /// A place nag waiting for its arrival or departure.
    public var isAwaitingPlace: Bool {
        placeTrigger != nil && completedAt == nil && startAt >= PlaceTrigger.waitingThreshold
    }

    /// Repeats on each arrival (or departure) rather than ending when it's done.
    public var repeatsAtPlace: Bool { placeTrigger?.repeats == true }

    /// Starts the current occurrence because the place event fired. Does nothing if the nag is already
    /// due, or is a one-off that's been done, so duplicate events are harmless.
    @discardableResult
    public mutating func startForPlace(at now: Date) -> Bool {
        guard placeTrigger != nil else { return false }
        let canStart = isAwaitingPlace || (repeatsAtPlace && completedAt != nil)
        guard canStart else { return false }
        startAt = now
        completedAt = nil
        snoozedUntil = nil
        snoozeCount = 0
        startedAt = nil
        completionUndo = nil
        updatedAt = now
        return true
    }

    /// Puts a place nag back to waiting for its place, keeping everything else.
    public mutating func waitForPlace() {
        guard placeTrigger != nil else { return }
        startAt = PlaceTrigger.waitingStart
        completedAt = nil
        snoozedUntil = nil
        snoozeCount = 0
        startedAt = nil
    }

    /// Finished nags that "Clear finished" may delete. Repeating place nags marked done by an older
    /// build look finished but come back on the next arrival.
    public var isClearable: Bool { isFinished && !repeatsAtPlace }
}

// MARK: - State

extension NagState {
    public func place(_ id: UUID) -> SavedPlace? { places.first { $0.id == id } }

    /// This device's place for a reference: the place itself, or the one the user linked it to.
    public func resolvedPlace(_ ref: PlaceRef?) -> SavedPlace? {
        guard let ref else { return nil }
        if let place = place(ref.id) { return place }
        return placeLinks[ref.id.uuidString].flatMap(place)
    }

    /// The name to show for a reference. Places this device doesn't have are labelled as such.
    public func placeName(_ ref: PlaceRef) -> String {
        if let place = resolvedPlace(ref) { return place.name }
        return "\(ref.name) (another device)"
    }

    public func isInside(_ placeID: UUID) -> Bool {
        placePresence[placeID.uuidString]?.inside == true
    }

    /// References from nags and locks that don't match a place on this device, for re-linking.
    public var unknownPlaceRefs: [PlaceRef] {
        var seen = Set<UUID>()
        let refs = tasks.compactMap(\.placeTrigger?.place) + profiles.compactMap(\.place)
        return refs.filter { resolvedPlace($0) == nil && seen.insert($0.id).inserted }
    }

    /// Adds or replaces a place. Renames reach the nags and locks that mention it.
    public mutating func savePlace(_ place: SavedPlace) {
        if let index = places.firstIndex(where: { $0.id == place.id }) {
            places[index] = place
        } else {
            places.append(place)
        }
        for index in profiles.indices where profiles[index].place?.id == place.id {
            profiles[index].place?.name = place.name
        }
    }

    /// Removes a place. Nags and locks that mention it stay, and show it as unknown on this device.
    public mutating func deletePlace(_ id: UUID) {
        places.removeAll { $0.id == id }
        placePresence[id.uuidString] = nil
        placeLinks = placeLinks.filter { $0.value != id }
    }

    /// Points a place from another device at one of this device's places, or unlinks it with `nil`.
    public mutating func linkPlace(_ ref: PlaceRef, to placeID: UUID?) {
        placeLinks[ref.id.uuidString] = placeID
    }

    /// Records whether this device is at a place, and starts nags waiting for that arrival or departure.
    ///
    /// The first report for a place only sets the starting point: being at home when monitoring begins
    /// isn't an arrival. Repeated reports of the same state change nothing. Locks catch up in
    /// `LockMaintenance.run`, which callers should run afterwards.
    /// - Returns: The nags that started.
    @discardableResult
    public mutating func applyPlaceObservation(placeID: UUID, inside: Bool, now: Date) -> [UUID] {
        guard place(placeID) != nil else { return [] }
        let key = placeID.uuidString
        let previous = placePresence[key]
        guard previous?.inside != inside else { return [] }
        placePresence[key] = PlacePresence(inside: inside, since: now)
        guard previous != nil else { return [] }

        let event: PlaceEvent = inside ? .arrive : .leave
        var started: [UUID] = []
        for index in tasks.indices {
            guard let trigger = tasks[index].placeTrigger, trigger.event == event,
                  resolvedPlace(trigger.place)?.id == placeID
            else { continue }
            if tasks[index].startForPlace(at: now) { started.append(tasks[index].id) }
        }
        return started
    }
}

// MARK: - Locks

extension LockProfile {
    /// Switches on once per visit to the lock's place, and releases place-made locks after leaving.
    /// - Parameter presence: Whether this device is at the lock's place, or `nil` when not known.
    @discardableResult
    public mutating func applyPlace(presence: PlacePresence?, now: Date) -> Bool {
        if place != nil, let presence, presence.inside {
            guard lastPlaceLockAt != presence.since else { return false }
            lastPlaceLockAt = presence.since
            if case .off = status {
                status = .locked(LockSession(startedAt: now, trigger: .place))
            }
            return true
        }
        // Left, or the place was removed from the lock or this device.
        if session?.trigger == .place, presence?.inside != true {
            status = .off
            return true
        }
        return false
    }
}

// MARK: - Monitoring

public enum PlaceMonitoring {
    /// iOS monitors at most 20 regions per app. The Mac uses the same cap.
    public static let regionLimit = 20

    /// The places to monitor, at most `limit`. Places locks depend on come first, then places active
    /// nags wait for, then the rest (so arrivals are known before anything uses them).
    public static func places(for state: NagState, limit: Int = regionLimit) -> [SavedPlace] {
        var rank: [UUID: Int] = [:]
        func consider(_ ref: PlaceRef?, _ tier: Int) {
            guard let place = state.resolvedPlace(ref) else { return }
            rank[place.id] = min(rank[place.id] ?? tier, tier)
        }
        for profile in state.profiles { consider(profile.place, 0) }
        for task in state.tasks where !task.isFinished || task.repeatsAtPlace {
            consider(task.placeTrigger?.place, 1)
        }
        return state.places
            .sorted { a, b in
                let (ra, rb) = (rank[a.id] ?? 2, rank[b.id] ?? 2)
                if ra != rb { return ra < rb }
                if a.name != b.name { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
                return a.id.uuidString < b.id.uuidString
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    /// How many places won't be monitored because of the cap.
    public static func overflow(for state: NagState, limit: Int = regionLimit) -> Int {
        max(0, state.places.count - limit)
    }
}

// MARK: - Sync

/// A nag's place trigger as stored in the sidecar iCloud key.
///
/// Builds without place support decode nags leniently but drop unknown fields when they save them
/// again. If one of them edits a place nag, its copy wins the merge without the trigger. Keeping
/// triggers under a separate key those builds never write means the trigger always survives.
public struct PlaceTriggerRecord: Codable, Hashable, Sendable {
    /// `nil` records a removed trigger.
    public var trigger: PlaceTrigger?
    public var changedAt: Date

    public init(trigger: PlaceTrigger?, changedAt: Date) {
        self.trigger = trigger
        self.changedAt = changedAt
    }
}

extension SyncedTasks {
    /// Triggers to store in the sidecar key, by nag ID.
    public var placeTriggerRecords: [String: PlaceTriggerRecord] {
        var records: [String: PlaceTriggerRecord] = [:]
        for task in tasks {
            guard let changedAt = task.placeTriggerChangedAt else { continue }
            records[task.id.uuidString] = PlaceTriggerRecord(trigger: task.placeTrigger, changedAt: changedAt)
        }
        return records
    }

    /// Restores triggers from the sidecar key where it's newer than what the nag itself carries.
    public func applyingPlaceTriggers(_ records: [String: PlaceTriggerRecord]) -> SyncedTasks {
        guard !records.isEmpty else { return self }
        var copy = self
        for index in copy.tasks.indices {
            guard let record = records[copy.tasks[index].id.uuidString],
                  record.changedAt > (copy.tasks[index].placeTriggerChangedAt ?? .distantPast)
            else { continue }
            copy.tasks[index].placeTrigger = record.trigger
            copy.tasks[index].placeTriggerChangedAt = record.changedAt
        }
        return copy
    }
}
