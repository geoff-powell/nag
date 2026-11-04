import Foundation

// MARK: - What a buddy sees

/// One nag or lock as an accountability buddy sees it. Deliberately tiny: a title, where it's at, when
/// it's due and when it was last done. Notes, keys, app selections, sources, links, snooze counts and
/// anything else about the item never leave the device.
public struct BuddyItem: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case nag
        case lock

        /// Unknown future kinds read as nags rather than making the item unreadable.
        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .nag
        }
    }

    public enum Status: String, Codable, Sendable {
        /// Nag: done ("did it"). Lock: unlocked, its requirements were met.
        case done
        /// Nag: due and not done ("still due"). Lock: locked.
        case due
        /// Nag: the owner tapped Started.
        case started
        /// Nag: not due yet. Lock: off.
        case upcoming

        /// Unknown future statuses read as "upcoming", which never invites a nudge.
        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .upcoming
        }
    }

    /// Longest title shared. Longer ones are cut, so a title can't smuggle out a paragraph of notes.
    public static let maxTitleLength = 80

    /// The nag's or lock's own ID.
    public var id: UUID
    public var kind: Kind
    public var title: String
    public var status: Status
    /// Nags: when the current or next occurrence starts. `nil` for finished one-off nags and locks.
    public var dueAt: Date?
    /// Nags: the last time it was done.
    public var lastDoneAt: Date?

    public init(id: UUID, kind: Kind, title: String, status: Status, dueAt: Date? = nil, lastDoneAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.title = String(title.prefix(Self.maxTitleLength))
        self.status = status
        self.dueAt = dueAt
        self.lastDoneAt = lastDoneAt
    }

    /// What the owner's nag looks like to a buddy.
    public init(task: NagTask, now: Date, calendar: Calendar) {
        let status: Status
        let dueAt: Date?
        if task.isFinished {
            status = .done
            dueAt = nil
        } else if task.isOutstanding(at: now) {
            status = task.isStarted(at: now) ? .started : .due
            dueAt = task.startAt
        } else if let last = task.lastCompletedAt, calendar.isDate(last, inSameDayAs: now) {
            // A repeating nag done today reads as "did it" until its next occurrence comes round.
            status = .done
            dueAt = task.startAt
        } else {
            status = .upcoming
            dueAt = task.startAt
        }
        self.init(id: task.id, kind: .nag, title: task.title, status: status, dueAt: dueAt, lastDoneAt: task.lastCompletedAt)
    }

    /// What the owner's lock looks like to a buddy: locked, unlocked, or off.
    public init(profile: LockProfile) {
        let status: Status = switch profile.status {
        case .locked: .due
        case .unlocked: .done
        case .off: .upcoming
        }
        self.init(id: profile.id, kind: .lock, title: profile.name, status: status)
    }

    /// The status to show at `now`. A nag the owner's phone last published as done or not yet due is
    /// still due once its next start has passed, even if the owner hasn't opened Nag since.
    public func displayStatus(at now: Date) -> Status {
        guard kind == .nag, status == .done || status == .upcoming, let dueAt, dueAt <= now else { return status }
        return .due
    }

    /// Low-pressure wording. There are no counts of misses and nothing says how late something is.
    public func statusLabel(at now: Date) -> String {
        switch (kind, displayStatus(at: now)) {
        case (.nag, .done): "Did it"
        case (.nag, .due): "Still due"
        case (.nag, .started): "Started"
        case (.nag, .upcoming): "Not due yet"
        case (.lock, .done): "Unlocked"
        case (.lock, .due), (.lock, .started): "Locked"
        case (.lock, .upcoming): "Off"
        }
    }

    /// Stored as a single CloudKit field, so new fields never need a schema change and older builds
    /// ignore fields they don't know.
    public func payload() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    public static func decode(_ payload: Data) -> BuddyItem? {
        guard var item = try? JSONDecoder().decode(BuddyItem.self, from: payload) else { return nil }
        item.title = String(item.title.prefix(maxTitleLength))
        return item
    }
}

// MARK: - Nudges

/// A single "thinking of you" from a buddy about one shared item. It carries no message of its own.
public struct BuddyNudge: Codable, Hashable, Identifiable, Sendable {
    /// Longest sender name shown in a notification.
    public static let maxNameLength = 40

    public var id: UUID
    public var itemID: UUID
    /// The buddy's name, as their iCloud account gives it. Empty if unknown.
    public var from: String
    public var sentAt: Date

    public init(id: UUID = UUID(), itemID: UUID, from: String, sentAt: Date) {
        self.id = id
        self.itemID = itemID
        self.from = String(from.prefix(Self.maxNameLength))
        self.sentAt = sentAt
    }

    public func payload() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    public static func decode(_ payload: Data) -> BuddyNudge? {
        guard let nudge = try? JSONDecoder().decode(BuddyNudge.self, from: payload) else { return nil }
        return BuddyNudge(id: nudge.id, itemID: nudge.itemID, from: nudge.from, sentAt: nudge.sentAt)
    }
}

/// When a buddy may nudge: only about something still due, and once per item until it's done again,
/// or every few hours at most.
public enum BuddyNudgeRule {
    public static let cooldown: TimeInterval = 4 * 3600

    /// When nudging `item` becomes possible again, or `nil` if it can be nudged now.
    /// Returns `.distantFuture` while the item isn't due, since there's nothing to nudge about.
    public static func nextNudgeAt(for item: BuddyItem, lastSentAt: Date?, now: Date) -> Date? {
        guard item.displayStatus(at: now) == .due else { return .distantFuture }
        guard let lastSentAt else { return nil }
        // Done since the last nudge, so this is a fresh occurrence.
        if let lastDoneAt = item.lastDoneAt, lastDoneAt > lastSentAt { return nil }
        let next = lastSentAt.addingTimeInterval(cooldown)
        return next > now ? next : nil
    }

    public static func canNudge(_ item: BuddyItem, lastSentAt: Date?, now: Date) -> Bool {
        nextNudgeAt(for: item, lastSentAt: lastSentAt, now: now) == nil
    }
}

/// A notification to show the owner about a nudge.
public struct BuddyNudgeNotice: Hashable, Sendable {
    public var itemID: UUID
    public var kind: BuddyItem.Kind
    public var title: String
    public var body: String
}

public struct BuddyNudgeDelivery: Hashable, Sendable {
    /// Notifications to show.
    public var notices: [BuddyNudgeNotice]
    /// Every nudge read, shown or not. All of them are deleted, so nothing is shown twice.
    public var consumed: [UUID]
    /// When each item last produced a notification, keyed by item ID.
    public var lastDelivered: [String: Date]
}

/// The owner's side of nudges. A buddy can write records into the shared zone, so the owner's device
/// enforces the limits again rather than trusting the buddy's app.
public enum BuddyNudgeInbox {
    /// Nudges older than this are dropped quietly: a nudge about yesterday doesn't help today.
    public static let maxAge: TimeInterval = 24 * 3600

    /// - Parameters:
    ///   - items: The owner's shared items as they are now.
    ///   - lastDelivered: When each item last produced a notification, keyed by item ID.
    public static func process(
        _ nudges: [BuddyNudge],
        items: [BuddyItem],
        lastDelivered: [String: Date],
        now: Date
    ) -> BuddyNudgeDelivery {
        let itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var delivered = lastDelivered
        var notices: [BuddyNudgeNotice] = []
        for nudge in nudges.sorted(by: { $0.sentAt < $1.sentAt }) {
            guard let item = itemsByID[nudge.itemID],
                  item.displayStatus(at: now) == .due,
                  now.timeIntervalSince(nudge.sentAt) < maxAge,
                  BuddyNudgeRule.canNudge(item, lastSentAt: delivered[item.id.uuidString], now: now)
            else { continue }
            delivered[item.id.uuidString] = now
            notices.append(notice(for: nudge, item: item))
        }
        // Forget items that aren't shared any more, so the record stays small.
        delivered = delivered.filter { key, _ in UUID(uuidString: key).map { itemsByID[$0] != nil } ?? false }
        return BuddyNudgeDelivery(notices: notices, consumed: nudges.map(\.id), lastDelivered: delivered)
    }

    static func notice(for nudge: BuddyNudge, item: BuddyItem) -> BuddyNudgeNotice {
        let name = nudge.from.trimmingCharacters(in: .whitespacesAndNewlines)
        let sender = name.isEmpty ? "Your buddy" : name
        return BuddyNudgeNotice(
            itemID: item.id,
            kind: item.kind,
            title: "\(sender) sent you a nudge",
            body: item.kind == .lock ? "About \(item.title). No pressure." : "About \(item.title). No pressure, whenever you're ready."
        )
    }
}

// MARK: - Publishing

/// Which items to share, kept apart from `NagTask` so the flag never touches the synced nag payload.
///
/// Older builds re-encode nags with only the keys they know, so a per-nag flag would be lost the moment
/// an older Mac edited the nag. The set lives in its own iCloud key-value entry
/// (`BuddySharedItems.storageKey`) instead, which older builds never read or write.
public struct BuddySharedItems: Codable, Hashable, Sendable {
    public static let storageKey = "nag.buddy.shared.v1"

    public var ids: Set<UUID>
    /// `.distantPast` when this device has never changed the set.
    public var updatedAt: Date

    public init(ids: Set<UUID> = [], updatedAt: Date = .distantPast) {
        self.ids = ids
        self.updatedAt = updatedAt
    }

    /// Last writer wins. On a tie both sides take the union, so they converge.
    public static func merge(_ a: BuddySharedItems, _ b: BuddySharedItems) -> BuddySharedItems {
        if a.updatedAt == b.updatedAt { return BuddySharedItems(ids: a.ids.union(b.ids), updatedAt: a.updatedAt) }
        return a.updatedAt > b.updatedAt ? a : b
    }
}

/// Buddy settings and bookkeeping, local to this device.
public struct BuddySettings: Codable, Hashable, Sendable {
    /// The owner turned on sharing. Nothing touches CloudKit until this or `following` is on.
    public var sharingEnabled: Bool
    public var shared: BuddySharedItems
    /// This device accepted someone's share.
    public var following: Bool
    /// Buddy side: when this device last nudged each item, keyed by item ID.
    public var sentNudges: [String: Date]
    /// Owner side: when each item last produced a nudge notification, keyed by item ID.
    public var receivedNudges: [String: Date]

    public init(
        sharingEnabled: Bool = false,
        shared: BuddySharedItems = BuddySharedItems(),
        following: Bool = false,
        sentNudges: [String: Date] = [:],
        receivedNudges: [String: Date] = [:]
    ) {
        self.sharingEnabled = sharingEnabled
        self.shared = shared
        self.following = following
        self.sentNudges = sentNudges
        self.receivedNudges = receivedNudges
    }

    private enum CodingKeys: String, CodingKey {
        case sharingEnabled, shared, following, sentNudges, receivedNudges
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sharingEnabled = try c.decodeIfPresent(Bool.self, forKey: .sharingEnabled) ?? false
        shared = try c.decodeIfPresent(BuddySharedItems.self, forKey: .shared) ?? BuddySharedItems()
        following = try c.decodeIfPresent(Bool.self, forKey: .following) ?? false
        sentNudges = try c.decodeIfPresent([String: Date].self, forKey: .sentNudges) ?? [:]
        receivedNudges = try c.decodeIfPresent([String: Date].self, forKey: .receivedNudges) ?? [:]
    }

    public var usesCloudKit: Bool { sharingEnabled || following }

    public func isShared(_ id: UUID) -> Bool { shared.ids.contains(id) }

    public mutating func setShared(_ id: UUID, _ isShared: Bool, at now: Date) {
        guard self.isShared(id) != isShared else { return }
        if isShared { shared.ids.insert(id) } else { shared.ids.remove(id) }
        shared.updatedAt = now
    }
}

/// What to write to and delete from the shared zone.
public struct BuddyChanges: Hashable, Sendable {
    public var upserts: [BuddyItem]
    public var deletions: [UUID]

    public var isEmpty: Bool { upserts.isEmpty && deletions.isEmpty }
}

public enum BuddyPlanner {
    /// The items to share right now: only the nags and locks the owner picked, and only when sharing is
    /// on. Sorted for a stable order.
    public static func items(for state: NagState, now: Date, calendar: Calendar) -> [BuddyItem] {
        let settings = state.buddy
        guard settings.sharingEnabled else { return [] }
        let nags = state.tasks
            .filter { settings.isShared($0.id) }
            .map { BuddyItem(task: $0, now: now, calendar: calendar) }
        let locks = state.profiles
            .filter { settings.isShared($0.id) }
            .map { BuddyItem(profile: $0) }
        return (nags + locks).sorted { ($0.kind.rawValue, $0.title, $0.id.uuidString) < ($1.kind.rawValue, $1.title, $1.id.uuidString) }
    }

    /// Brings the zone in line with `desired`. Records for items no longer shared, or for deleted nags,
    /// go. Records for shared IDs that don't exist here are left alone: they may be another device's
    /// lock, since locks don't sync.
    public static func changes(
        desired: [BuddyItem],
        remote: [BuddyItem],
        sharedIDs: Set<UUID>,
        deletedTaskIDs: Set<UUID>
    ) -> BuddyChanges {
        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let upserts = desired.filter { remoteByID[$0.id] != $0 }
        let deletions = remote
            .map(\.id)
            .filter { !sharedIDs.contains($0) || deletedTaskIDs.contains($0) }
        return BuddyChanges(upserts: upserts, deletions: Array(Set(deletions)).sorted { $0.uuidString < $1.uuidString })
    }
}

extension NagState {
    public var deletedTaskIDs: Set<UUID> {
        Set(deletedTasks.keys.compactMap(UUID.init(uuidString:)))
    }

    /// Drops deleted nags from the shared set, so a re-created nag with the same ID isn't shared by
    /// surprise. Returns whether anything changed.
    @discardableResult
    public mutating func pruneDeletedBuddyItems(at now: Date) -> Bool {
        let stale = buddy.shared.ids.intersection(deletedTaskIDs)
        guard !stale.isEmpty else { return false }
        buddy.shared.ids.subtract(stale)
        buddy.shared.updatedAt = now
        return true
    }
}
