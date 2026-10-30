import Foundation

// MARK: - Nags

/// How a nag comes back after it's done.
public enum RepeatRule: String, Codable, CaseIterable, Sendable {
    case never
    case daily
    case weekdays
    case weekly
    /// Comes back at each of the nag's `times`, such as 9 AM Mon, Wed, Fri and 11 PM Tue, Thu.
    case custom

    public var label: String {
        switch self {
        case .never: "Once"
        case .daily: "Every day"
        case .weekdays: "Weekdays"
        case .weekly: "Every week"
        case .custom: "Custom"
        }
    }
}

/// One time of day a custom-schedule nag comes due, on the chosen days.
public struct NagTime: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Minutes after midnight.
    public var minute: Int
    /// Calendar weekday numbers (1 = Sunday … 7 = Saturday).
    public var weekdays: Set<Int>

    public init(id: UUID = UUID(), minute: Int = 9 * 60, weekdays: Set<Int> = Set(1...7)) {
        self.id = id
        self.minute = minute
        self.weekdays = weekdays
    }
}

/// How the nag interval tightens the longer a nag stays undone.
public enum Escalation: String, Codable, CaseIterable, Sendable {
    case steady
    case gentle
    case relentless

    public var label: String {
        switch self {
        case .steady: "Steady"
        case .gentle: "Gentle"
        case .relentless: "Relentless"
        }
    }

    public var explanation: String {
        switch self {
        case .steady: "Nags at the same pace until it's done."
        case .gentle: "Nags a bit more often for every hour it's overdue, up to twice as often."
        case .relentless: "Doubles the pace every 30 minutes it's overdue, down to once a minute."
        }
    }
}

public struct NagStyle: Codable, Hashable, Sendable {
    public var intervalMinutes: Int
    public var escalation: Escalation
    public var snoozeMinutes: Int
    /// `nil` allows unlimited snoozes.
    public var maxSnoozes: Int?
    /// Deliver nags as Time Sensitive so they can break through Focus.
    public var breakThroughFocus: Bool
    /// How long a nag stays quiet after it is started.
    public var workMinutes: Int

    public init(
        intervalMinutes: Int = 15,
        escalation: Escalation = .gentle,
        snoozeMinutes: Int = 10,
        maxSnoozes: Int? = 3,
        breakThroughFocus: Bool = true,
        workMinutes: Int = 30
    ) {
        self.intervalMinutes = intervalMinutes
        self.escalation = escalation
        self.snoozeMinutes = snoozeMinutes
        self.maxSnoozes = maxSnoozes
        self.breakThroughFocus = breakThroughFocus
        self.workMinutes = workMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case intervalMinutes, escalation, snoozeMinutes, maxSnoozes, breakThroughFocus, workMinutes
    }

    /// Every field has its original default so styles saved by older versions still load.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 15
        escalation = try c.decodeIfPresent(Escalation.self, forKey: .escalation) ?? .gentle
        snoozeMinutes = try c.decodeIfPresent(Int.self, forKey: .snoozeMinutes) ?? 10
        maxSnoozes = try c.decodeIfPresent(Int.self, forKey: .maxSnoozes)
        breakThroughFocus = try c.decodeIfPresent(Bool.self, forKey: .breakThroughFocus) ?? true
        workMinutes = min(max(try c.decodeIfPresent(Int.self, forKey: .workMinutes) ?? 30, 1), 1440)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(intervalMinutes, forKey: .intervalMinutes)
        try c.encode(escalation, forKey: .escalation)
        try c.encode(snoozeMinutes, forKey: .snoozeMinutes)
        try c.encodeIfPresent(maxSnoozes, forKey: .maxSnoozes)
        try c.encode(breakThroughFocus, forKey: .breakThroughFocus)
        try c.encode(workMinutes, forKey: .workMinutes)
    }
}

/// What it takes to mark a nag done.
public enum CompletionProof: Codable, Hashable, Sendable {
    case none
    /// Scan a paired NFC tag or code, such as a sticker on the pill bottle.
    case scanKey(UUID)

    public var keyID: UUID? {
        switch self {
        case .none: nil
        case .scanKey(let id): id
        }
    }
}

/// The state a nag was in just before it was completed, so the completion can be undone.
public struct CompletionUndo: Codable, Hashable, Sendable {
    public var startAt: Date
    public var snoozedUntil: Date?
    public var snoozeCount: Int
    public var lastCompletedAt: Date?
    public var completedAt: Date?
    public var startedAt: Date?
    /// The completion this snapshot can undo.
    public var completedAtMoment: Date

    public init(
        startAt: Date,
        snoozedUntil: Date?,
        snoozeCount: Int,
        lastCompletedAt: Date?,
        completedAt: Date?,
        startedAt: Date?,
        completedAtMoment: Date
    ) {
        self.startAt = startAt
        self.snoozedUntil = snoozedUntil
        self.snoozeCount = snoozeCount
        self.lastCompletedAt = lastCompletedAt
        self.completedAt = completedAt
        self.startedAt = startedAt
        self.completedAtMoment = completedAtMoment
    }

    private enum CodingKeys: String, CodingKey {
        case startAt, snoozedUntil, snoozeCount, lastCompletedAt, completedAt, startedAt, completedAtMoment
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startAt = try c.decode(Date.self, forKey: .startAt)
        snoozedUntil = try c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        snoozeCount = try c.decode(Int.self, forKey: .snoozeCount)
        lastCompletedAt = try c.decodeIfPresent(Date.self, forKey: .lastCompletedAt)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAtMoment = try c.decode(Date.self, forKey: .completedAtMoment)
    }
}

public struct NagTask: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var notes: String
    public var createdAt: Date
    /// Last change on any device. Used to merge copies synced through iCloud.
    public var updatedAt: Date
    /// Start of the current occurrence. Nagging begins here.
    public var startAt: Date
    public var repeatRule: RepeatRule
    /// When a `.custom` nag comes due. Ignored by the other repeat rules.
    public var times: [NagTime]
    public var style: NagStyle
    public var proof: CompletionProof
    /// Set when a one-off nag is done. Repeating nags move `startAt` to the next occurrence instead.
    public var completedAt: Date?
    public var lastCompletedAt: Date?
    public var snoozedUntil: Date?
    /// When the current occurrence was started.
    public var startedAt: Date?
    /// Snoozes used on the current occurrence.
    public var snoozeCount: Int
    public var completionUndo: CompletionUndo?
    public var undoneCompletionAt: Date?
    /// What made this nag outside Nag, such as "Calendar", "Muse" or "Claude". `nil` for nags made in Nag.
    public var source: String?
    /// The source's own ID for the item, so sending the same item again updates this nag instead of
    /// adding another.
    public var externalID: String?
    /// Opens the item the nag came from: a note, an event, a Muse board.
    public var link: URL?

    public init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        startAt: Date = .now,
        repeatRule: RepeatRule = .never,
        times: [NagTime] = [],
        style: NagStyle = NagStyle(),
        proof: CompletionProof = .none,
        source: String? = nil,
        externalID: String? = nil,
        link: URL? = nil,
        now: Date = .now
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.createdAt = now
        self.updatedAt = now
        self.startAt = startAt
        self.repeatRule = repeatRule
        self.times = times
        self.style = style
        self.proof = proof
        self.completedAt = nil
        self.lastCompletedAt = nil
        self.snoozedUntil = nil
        self.startedAt = nil
        self.snoozeCount = 0
        self.completionUndo = nil
        self.undoneCompletionAt = nil
        self.source = source
        self.externalID = externalID
        self.link = link
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, notes, createdAt, updatedAt, startAt, repeatRule, times, style, proof
        case completedAt, lastCompletedAt, snoozedUntil, startedAt, snoozeCount
        case completionUndo, undoneCompletionAt
        case source, externalID, link
    }

    /// `times`, `source`, `externalID` and `link` are optional so nags saved by older versions still load.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decode(String.self, forKey: .notes)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        startAt = try c.decode(Date.self, forKey: .startAt)
        repeatRule = try c.decode(RepeatRule.self, forKey: .repeatRule)
        times = try c.decodeIfPresent([NagTime].self, forKey: .times) ?? []
        style = try c.decode(NagStyle.self, forKey: .style)
        proof = try c.decode(CompletionProof.self, forKey: .proof)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        lastCompletedAt = try c.decodeIfPresent(Date.self, forKey: .lastCompletedAt)
        snoozedUntil = try c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        snoozeCount = try c.decode(Int.self, forKey: .snoozeCount)
        completionUndo = try c.decodeIfPresent(CompletionUndo.self, forKey: .completionUndo)
        undoneCompletionAt = try c.decodeIfPresent(Date.self, forKey: .undoneCompletionAt)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        externalID = try c.decodeIfPresent(String.self, forKey: .externalID)
        link = try c.decodeIfPresent(URL.self, forKey: .link)
    }
}

// MARK: - Locks

/// A daily window during which a lock switches itself on.
public struct LockSchedule: Codable, Hashable, Sendable {
    /// Minutes after midnight.
    public var startMinute: Int
    /// Minutes after midnight. Earlier than `startMinute` means the window runs past midnight.
    public var endMinute: Int
    /// Calendar weekday numbers (1 = Sunday … 7 = Saturday) of the days a window starts on.
    public var weekdays: Set<Int>

    public init(startMinute: Int = 9 * 60, endMinute: Int = 17 * 60, weekdays: Set<Int> = [2, 3, 4, 5, 6]) {
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.weekdays = weekdays
    }
}

/// Counts of what a lock blocks, for display. The selection itself is platform specific.
public struct SelectionSummary: Codable, Hashable, Sendable {
    public var apps: Int
    public var categories: Int
    public var webDomains: Int

    public init(apps: Int = 0, categories: Int = 0, webDomains: Int = 0) {
        self.apps = apps
        self.categories = categories
        self.webDomains = webDomains
    }

    public var isEmpty: Bool { apps + categories + webDomains == 0 }

    public var label: String {
        var parts: [String] = []
        if apps > 0 { parts.append(apps == 1 ? "1 app" : "\(apps) apps") }
        if categories > 0 { parts.append(categories == 1 ? "1 category" : "\(categories) categories") }
        if webDomains > 0 { parts.append(webDomains == 1 ? "1 website" : "\(webDomains) websites") }
        return parts.isEmpty ? "Nothing selected" : parts.joined(separator: ", ")
    }
}

public struct UnlockRequirement: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        /// Finish these nags. For repeating nags, today's occurrence.
        case completeTasks([UUID])
        /// No nag may be due or overdue.
        case clearDueNags
        /// Scan a paired NFC tag or code.
        case scanKey(UUID)
        /// Walk this many steps after the lock started.
        case walk(steps: Int)
        /// Start a timer, then wait it out.
        case wait(minutes: Int)
        /// Type this phrase exactly.
        case typePhrase(String)
    }

    public var id: UUID
    public var kind: Kind

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

/// What switched a lock on. Decides what switches it off again.
public enum LockTrigger: String, Codable, Sendable {
    case manual
    case schedule
    case nags
}

public struct LockSession: Codable, Hashable, Sendable {
    public var startedAt: Date
    public var trigger: LockTrigger
    /// When the wait timer was started.
    public var unlockRequestedAt: Date?
    /// Requirements proven during this session (key scans, typed phrases).
    public var proofs: Set<UUID>

    public init(startedAt: Date, trigger: LockTrigger = .manual) {
        self.startedAt = startedAt
        self.trigger = trigger
        self.unlockRequestedAt = nil
        self.proofs = []
    }
}

public enum LockStatus: Codable, Hashable, Sendable {
    case off
    case locked(LockSession)
    /// Requirements were met. Apps are open until `until`, then the lock comes back.
    case unlocked(LockSession, until: Date)
}

public struct LockProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// SF Symbol name.
    public var symbol: String
    /// Platform-specific encoded selection: `FamilyActivitySelection` on iOS, a list of apps on macOS.
    public var selection: Data
    public var selectionSummary: SelectionSummary
    public var requirements: [UnlockRequirement]
    /// Unlock as soon as the requirements are met, without opening Nag.
    public var autoUnlock: Bool
    /// How long apps stay open after a timer, walk, scan or phrase unlock. `nil` switches the lock off.
    public var unlockMinutes: Int?
    public var schedule: LockSchedule?
    /// Switch on whenever any nag is due, and stay on until they're cleared.
    public var lockWhileNagsDue: Bool
    /// iOS: apps can't be deleted while locked. macOS: blocked apps are quit and Nag refuses to quit.
    public var strict: Bool
    public var message: String
    public var status: LockStatus
    /// Start of the last schedule window that switched this lock on.
    public var lastScheduledLockAt: Date?
    /// After an emergency unlock, due nags don't switch the lock back on until this time.
    public var autoLockPausedUntil: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        symbol: String = "lock.fill",
        selection: Data = Data(),
        selectionSummary: SelectionSummary = SelectionSummary(),
        requirements: [UnlockRequirement] = [],
        autoUnlock: Bool = true,
        unlockMinutes: Int? = 30,
        schedule: LockSchedule? = nil,
        lockWhileNagsDue: Bool = false,
        strict: Bool = false,
        message: String = "Do the thing first. Future you will thank you."
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.selection = selection
        self.selectionSummary = selectionSummary
        self.requirements = requirements
        self.autoUnlock = autoUnlock
        self.unlockMinutes = unlockMinutes
        self.schedule = schedule
        self.lockWhileNagsDue = lockWhileNagsDue
        self.strict = strict
        self.message = message
        self.status = .off
        self.lastScheduledLockAt = nil
        self.autoLockPausedUntil = nil
    }
}

// MARK: - Keys

/// Something physical to scan, like Brick's tag: an NFC sticker, a printed QR code, or any barcode.
public struct UnlockKey: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case nfc
        case code
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// Hash of the tag ID or code contents. The raw value is never stored.
    public var fingerprint: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, kind: Kind, fingerprint: String, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.kind = kind
        self.fingerprint = fingerprint
        self.createdAt = createdAt
    }
}

// MARK: - Settings

public struct QuietHours: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var startMinute: Int
    public var endMinute: Int

    public init(enabled: Bool = false, startMinute: Int = 22 * 60, endMinute: Int = 8 * 60) {
        self.enabled = enabled
        self.startMinute = startMinute
        self.endMinute = endMinute
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var quietHours: QuietHours
    public var emergencyUnlocksPerMonth: Int
    public var emergencyUnlocksUsed: [Date]
    public var hasOnboarded: Bool
    /// Screen Time access was granted, so DeviceActivity can wake Nag in the background (iOS).
    public var screenTimeApproved: Bool

    public init(
        quietHours: QuietHours = QuietHours(),
        emergencyUnlocksPerMonth: Int = 3,
        emergencyUnlocksUsed: [Date] = [],
        hasOnboarded: Bool = false,
        screenTimeApproved: Bool = false
    ) {
        self.quietHours = quietHours
        self.emergencyUnlocksPerMonth = emergencyUnlocksPerMonth
        self.emergencyUnlocksUsed = emergencyUnlocksUsed
        self.hasOnboarded = hasOnboarded
        self.screenTimeApproved = screenTimeApproved
    }

    private enum CodingKeys: String, CodingKey {
        case quietHours, emergencyUnlocksPerMonth, emergencyUnlocksUsed, hasOnboarded, screenTimeApproved
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quietHours = try c.decodeIfPresent(QuietHours.self, forKey: .quietHours) ?? QuietHours()
        emergencyUnlocksPerMonth = try c.decodeIfPresent(Int.self, forKey: .emergencyUnlocksPerMonth) ?? 3
        emergencyUnlocksUsed = try c.decodeIfPresent([Date].self, forKey: .emergencyUnlocksUsed) ?? []
        hasOnboarded = try c.decodeIfPresent(Bool.self, forKey: .hasOnboarded) ?? false
        screenTimeApproved = try c.decodeIfPresent(Bool.self, forKey: .screenTimeApproved) ?? false
    }
}

// MARK: - State

/// Everything Nag stores. Shared between the app and its extensions through the app group.
public struct NagState: Codable, Hashable, Sendable {
    public var tasks: [NagTask]
    public var profiles: [LockProfile]
    public var keys: [UnlockKey]
    public var settings: AppSettings
    /// IDs of deleted nags and when they were deleted, so deletions sync between devices.
    public var deletedTasks: [String: Date]

    public init(
        tasks: [NagTask] = [],
        profiles: [LockProfile] = [],
        keys: [UnlockKey] = [],
        settings: AppSettings = AppSettings(),
        deletedTasks: [String: Date] = [:]
    ) {
        self.tasks = tasks
        self.profiles = profiles
        self.keys = keys
        self.settings = settings
        self.deletedTasks = deletedTasks
    }

    private enum CodingKeys: String, CodingKey {
        case tasks, profiles, keys, settings, deletedTasks
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try c.decodeIfPresent([NagTask].self, forKey: .tasks) ?? []
        profiles = try c.decodeIfPresent([LockProfile].self, forKey: .profiles) ?? []
        keys = try c.decodeIfPresent([UnlockKey].self, forKey: .keys) ?? []
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        deletedTasks = try c.decodeIfPresent([String: Date].self, forKey: .deletedTasks) ?? [:]
    }

    public func task(_ id: UUID) -> NagTask? { tasks.first { $0.id == id } }
    public func profile(_ id: UUID) -> LockProfile? { profiles.first { $0.id == id } }
    public func key(_ id: UUID) -> UnlockKey? { keys.first { $0.id == id } }

    public var anyLockEngaged: Bool { profiles.contains { $0.isEngaged } }

    /// Nags an engaged lock depends on can't be deleted, or deleting them would be a way out.
    public func isTaskRequiredByEngagedLock(_ taskID: UUID) -> Bool {
        profiles.contains { profile in
            profile.isEngaged && profile.requirements.contains { requirement in
                if case .completeTasks(let ids) = requirement.kind { return ids.contains(taskID) }
                return false
            }
        }
    }

    public func isKeyRequiredByEngagedLock(_ keyID: UUID) -> Bool {
        profiles.contains { profile in
            profile.isEngaged && profile.requirements.contains { $0.kind == .scanKey(keyID) }
        }
    }

    /// Emergency unlocks left in the calendar month containing `now`.
    public func emergencyUnlocksLeft(at now: Date, calendar: Calendar) -> Int {
        let used = settings.emergencyUnlocksUsed.filter { calendar.isDate($0, equalTo: now, toGranularity: .month) }.count
        return max(0, settings.emergencyUnlocksPerMonth - used)
    }
}
