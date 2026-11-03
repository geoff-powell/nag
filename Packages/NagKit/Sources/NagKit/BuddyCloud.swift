@preconcurrency import CloudKit
import Foundation
import NagCore
@preconcurrency import UserNotifications

/// Someone who shared their nags with this device: their name and what they chose to share.
public struct BuddyFriend: Hashable, Identifiable, Sendable {
    public var zoneName: String
    public var ownerName: String
    public var name: String
    public var items: [BuddyItem]
    /// This person's name for themselves as a participant, sent with nudges.
    public var myName: String

    public var id: String { "\(ownerName)/\(zoneName)" }

    public init(zoneName: String, ownerName: String, name: String, items: [BuddyItem], myName: String) {
        self.zoneName = zoneName
        self.ownerName = ownerName
        self.name = name
        self.items = items
        self.myName = myName
    }
}

/// What's in the owner's buddy zone.
public struct BuddyZoneContents: Sendable {
    public var items: [BuddyItem]
    public var nudges: [BuddyNudge]

    public init(items: [BuddyItem] = [], nudges: [BuddyNudge] = []) {
        self.items = items
        self.nudges = nudges
    }
}

/// The CloudKit side of accountability buddies. Thin on purpose: what to share, what changed, and which
/// nudges to show are all decided in NagCore (`BuddyPlanner`, `BuddyNudgeInbox`, `BuddyNudgeRule`).
public protocol BuddyCloudService: Sendable {
    /// Owner: creates the zone and a subscription for changes in it. Safe to call repeatedly.
    func prepareOwnZone() async throws
    func fetchOwnZone() async throws -> BuddyZoneContents
    func apply(_ changes: BuddyChanges, deletingNudges: [UUID]) async throws
    /// Owner: the zone-wide share, created if needed, for the sharing sheet.
    func share() async throws -> CKShare
    /// Owner: deletes the zone and with it the share and every record. The buddy loses access at once.
    func stopSharing() async throws

    /// Buddy: accepts an invitation.
    func accept(_ metadata: CKShare.Metadata) async throws
    func fetchFriends() async throws -> [BuddyFriend]
    func sendNudge(_ nudge: BuddyNudge, to friend: BuddyFriend) async throws
    /// Buddy: leaves someone's share.
    func leave(_ friend: BuddyFriend) async throws

    var container: CKContainer { get }
}

/// `BuddyCloudService` backed by the app's CloudKit container. The owner's records live in a custom
/// zone in their private database, shared zone-wide with one buddy, who can add nudge records.
public final class CloudBuddyService: BuddyCloudService, @unchecked Sendable {
    /// Info.plist key holding the container identifier (set from `NAG_CLOUDKIT_CONTAINER`).
    public static let containerInfoKey = "NagCloudContainer"
    static let zoneName = "Buddy"
    static let subscriptionID = "buddy-zone"

    enum RecordType {
        static let item = "BuddyItem"
        static let nudge = "BuddyNudge"
    }

    static let payloadKey = "payload"

    public let container: CKContainer
    private var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName) }

    public init(container: CKContainer) {
        self.container = container
    }

    /// The container named in Info.plist, or `nil` when the build doesn't have one configured.
    public static func fromBundle(_ bundle: Bundle = .main) -> CloudBuddyService? {
        guard let identifier = bundle.object(forInfoDictionaryKey: containerInfoKey) as? String,
              !identifier.isEmpty, !identifier.contains("$(")
        else { return nil }
        return CloudBuddyService(container: CKContainer(identifier: identifier))
    }

    // MARK: Owner

    public func prepareOwnZone() async throws {
        let database = container.privateCloudDatabase
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: Self.subscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await database.save(subscription)
    }

    public func fetchOwnZone() async throws -> BuddyZoneContents {
        let records = try await allRecords(in: zoneID, database: container.privateCloudDatabase)
        var contents = BuddyZoneContents()
        for record in records {
            guard let payload = record[Self.payloadKey] as? Data else { continue }
            switch record.recordType {
            case RecordType.item: BuddyItem.decode(payload).map { contents.items.append($0) }
            case RecordType.nudge:
                // The record name is the nudge's ID, whatever the payload claims, so it can be deleted.
                if var nudge = BuddyNudge.decode(payload), let id = UUID(uuidString: record.recordID.recordName) {
                    nudge.id = id
                    contents.nudges.append(nudge)
                }
            default: break
            }
        }
        return contents
    }

    public func apply(_ changes: BuddyChanges, deletingNudges: [UUID]) async throws {
        let saving = changes.upserts.map { item -> CKRecord in
            let record = CKRecord(recordType: RecordType.item, recordID: CKRecord.ID(recordName: item.id.uuidString, zoneID: zoneID))
            record[Self.payloadKey] = item.payload() as NSData
            return record
        }
        let deleting = (changes.deletions + deletingNudges).map { CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID) }
        guard !saving.isEmpty || !deleting.isEmpty else { return }
        _ = try await container.privateCloudDatabase.modifyRecords(
            saving: saving,
            deleting: deleting,
            savePolicy: .allKeys,
            atomically: false
        )
    }

    public func share() async throws -> CKShare {
        let database = container.privateCloudDatabase
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        do {
            if let existing = try await database.record(for: shareID) as? CKShare { return existing }
        } catch let error as CKError where error.code == .unknownItem {
            // No share yet.
        }
        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = "My nags" as NSString
        share.publicPermission = .none
        _ = try await database.modifyRecords(saving: [share], deleting: [])
        return share
    }

    public func stopSharing() async throws {
        do {
            _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [], deleting: [zoneID])
        } catch let error as CKError where error.code == .zoneNotFound {
            // Already gone.
        }
        _ = try? await container.privateCloudDatabase.deleteSubscription(withID: Self.subscriptionID)
    }

    // MARK: Buddy

    public func accept(_ metadata: CKShare.Metadata) async throws {
        _ = try await container.accept(metadata)
    }

    public func fetchFriends() async throws -> [BuddyFriend] {
        let database = container.sharedCloudDatabase
        var friends: [BuddyFriend] = []
        for zone in try await database.allRecordZones() {
            let records = try await allRecords(in: zone.zoneID, database: database)
            var items: [BuddyItem] = []
            var name = "Your buddy"
            var myName = ""
            for record in records {
                if let share = record as? CKShare {
                    name = Self.displayName(share.owner.userIdentity.nameComponents) ?? name
                    myName = Self.displayName(share.currentUserParticipant?.userIdentity.nameComponents) ?? ""
                } else if record.recordType == RecordType.item, let payload = record[Self.payloadKey] as? Data,
                          let item = BuddyItem.decode(payload) {
                    items.append(item)
                }
            }
            friends.append(BuddyFriend(
                zoneName: zone.zoneID.zoneName,
                ownerName: zone.zoneID.ownerName,
                name: name,
                items: items.sorted { ($0.kind.rawValue, $0.title) < ($1.kind.rawValue, $1.title) },
                myName: myName
            ))
        }
        return friends.sorted { $0.name < $1.name }
    }

    public func sendNudge(_ nudge: BuddyNudge, to friend: BuddyFriend) async throws {
        let zone = CKRecordZone.ID(zoneName: friend.zoneName, ownerName: friend.ownerName)
        let record = CKRecord(recordType: RecordType.nudge, recordID: CKRecord.ID(recordName: nudge.id.uuidString, zoneID: zone))
        record[Self.payloadKey] = nudge.payload() as NSData
        _ = try await container.sharedCloudDatabase.modifyRecords(saving: [record], deleting: [])
    }

    public func leave(_ friend: BuddyFriend) async throws {
        let zone = CKRecordZone.ID(zoneName: friend.zoneName, ownerName: friend.ownerName)
        _ = try await container.sharedCloudDatabase.modifyRecordZones(saving: [], deleting: [zone])
    }

    // MARK: Helpers

    /// Every record in a zone. The zones are tiny, so this reads from the start each time instead of
    /// keeping change tokens, and needs no queryable indexes in the CloudKit schema.
    private func allRecords(in zoneID: CKRecordZone.ID, database: CKDatabase) async throws -> [CKRecord] {
        var records: [CKRecord] = []
        var token: CKServerChangeToken?
        var moreComing = true
        while moreComing {
            let changes: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, any Error>],
                          deletions: [CKDatabase.RecordZoneChange.Deletion],
                          changeToken: CKServerChangeToken,
                          moreComing: Bool)
            do {
                changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            } catch let error as CKError where error.code == .zoneNotFound {
                return []
            }
            records += changes.modificationResultsByID.values.compactMap { try? $0.get().record }
            token = changes.changeToken
            moreComing = changes.moreComing
        }
        return records
    }

    static func displayName(_ components: PersonNameComponents?) -> String? {
        guard let components else { return nil }
        let formatter = PersonNameComponentsFormatter()
        formatter.style = .short
        let name = formatter.string(from: components).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Whether a remote notification is a CloudKit change notification.
    public static func isCloudKitNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        CKNotification(fromRemoteNotificationDictionary: userInfo) != nil
    }
}

extension NotificationSync {
    /// A gentle notification for a buddy's nudge. Never Time Sensitive.
    public static func buddyNudge(_ notice: BuddyNudgeNotice) async {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        content.categoryIdentifier = NagID.Category.alert
        content.interruptionLevel = .active
        let key = notice.kind == .lock ? NagID.UserInfo.profileID : NagID.UserInfo.taskID
        content.userInfo = [key: notice.itemID.uuidString]
        let request = UNNotificationRequest(identifier: "nag.buddy.\(notice.itemID.uuidString)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
