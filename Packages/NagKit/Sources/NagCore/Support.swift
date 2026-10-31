import CryptoKit
import Foundation

/// Identifiers shared by the app, its extensions and the Mac app.
public enum NagID {
    /// Info.plist key holding the app group identifier (set from the APP_GROUP_ID build setting).
    public static let appGroupInfoKey = "NagAppGroup"
    /// Every nag notification identifier starts with this, so sync never touches other notifications.
    public static let nagNotificationPrefix = "nag|"

    public enum Category {
        public static let nag = "NAG"
        public static let nagNoSnooze = "NAG_NO_SNOOZE"
        public static let proof = "NAG_PROOF"
        public static let proofNoSnooze = "NAG_PROOF_NO_SNOOZE"
        public static let alert = "NAG_ALERT"
        public static let undo = "NAG_UNDO"

        public static func forTask(_ task: NagTask, canSnooze: Bool) -> String {
            switch (task.proof.keyID != nil, canSnooze) {
            case (false, true): nag
            case (false, false): nagNoSnooze
            case (true, true): proof
            case (true, false): proofNoSnooze
            }
        }
    }

    public enum Action {
        public static let done = "DONE"
        public static let snooze = "SNOOZE"
        public static let snooze5 = "SNOOZE_5"
        public static let snooze15 = "SNOOZE_15"
        public static let snooze60 = "SNOOZE_60"
        public static let scan = "SCAN"
        public static let undo = "UNDO"
    }

    public enum UserInfo {
        public static let taskID = "taskID"
        public static let profileID = "profileID"
    }

    /// DeviceActivity names (iOS).
    public enum Activity {
        public static let wake = "nag.wake"
        public static let quiet = "nag.quiet"
        public static let schedulePrefix = "lock.schedule."
        public static let relockPrefix = "lock.relock."

        public static func schedule(_ profileID: UUID) -> String { schedulePrefix + profileID.uuidString }
        public static func relock(_ profileID: UUID) -> String { relockPrefix + profileID.uuidString }

        public static func profileID(in name: String, prefix: String) -> UUID? {
            guard name.hasPrefix(prefix) else { return nil }
            return UUID(uuidString: String(name.dropFirst(prefix.count)))
        }

        public static func isNag(_ name: String) -> Bool {
            name == wake || name == quiet || name.hasPrefix(schedulePrefix) || name.hasPrefix(relockPrefix)
        }
    }
}

/// Fingerprints for unlock keys. Only hashes are stored, never tag IDs or code contents.
public enum KeyFingerprint {
    public static func nfc(_ identifier: Data) -> String {
        "nfc:" + sha256(identifier)
    }

    public static func code(_ payload: String) -> String {
        "code:" + sha256(Data(payload.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    }

    /// Contents for a new printable QR key.
    public static func newCodePayload() -> String {
        "NAG-KEY-" + UUID().uuidString + "-" + UUID().uuidString.prefix(8)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// FNV-1a. Unlike `hashValue`, stable across processes and launches.
public enum StableHash {
    public static func hex(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

public enum NagFormat {
    /// "45m", "1h 20m", "2d 3h".
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes < 1 { return "under a minute" }
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let mins = minutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h" }
        return "\(mins)m"
    }

    /// "1 min", "15 min", "1 hr", "1 hr 30 min".
    public static func minutes(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    /// "4:05".
    public static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// "9:00 AM" for minutes after midnight.
    public static func timeOfDay(_ minuteOfDay: Int, calendar: Calendar = .current) -> String {
        let date = calendar.date(bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// "Weekdays", "Every day", "Mon, Wed, Fri".
    public static func weekdays(_ days: Set<Int>, calendar: Calendar = .current) -> String {
        if days.count == 7 { return "Every day" }
        if days == [2, 3, 4, 5, 6] { return "Weekdays" }
        if days == [1, 7] { return "Weekends" }
        let symbols = calendar.shortWeekdaySymbols
        let ordered = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        return ordered.filter(days.contains).map { symbols[$0 - 1] }.joined(separator: ", ")
    }
}

extension LockSchedule {
    public var label: String {
        "\(NagFormat.timeOfDay(startMinute)) – \(NagFormat.timeOfDay(endMinute)), \(NagFormat.weekdays(weekdays))"
    }
}

extension NagTime {
    /// "9:00 AM Mon, Wed, Fri".
    public var label: String {
        "\(NagFormat.timeOfDay(minute)) \(NagFormat.weekdays(weekdays))"
    }
}

extension NagTask {
    /// "Every day", or each custom time: "9:00 AM Mon, Wed, Fri · 11:00 PM Tue, Thu".
    public var repeatLabel: String {
        guard repeatRule == .custom, !times.isEmpty else { return repeatRule.label }
        return times.sorted { $0.minute < $1.minute }.map(\.label).joined(separator: " · ")
    }
}
