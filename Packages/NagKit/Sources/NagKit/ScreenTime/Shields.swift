#if os(iOS)
@preconcurrency import FamilyControls
import Foundation
@preconcurrency import ManagedSettings
import NagCore

public enum SelectionCoding {
    public static func encode(_ selection: FamilyActivitySelection) -> Data {
        (try? JSONEncoder().encode(selection)) ?? Data()
    }

    public static func decode(_ data: Data) -> FamilyActivitySelection? {
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
    }

    public static func summary(of selection: FamilyActivitySelection) -> SelectionSummary {
        SelectionSummary(
            apps: selection.applicationTokens.count,
            categories: selection.categoryTokens.count,
            webDomains: selection.webDomainTokens.count
        )
    }
}

/// Applies each lock's shields through its own named ManagedSettings store, so locks never
/// overwrite each other.
public enum ShieldController {
    static func storeName(for profileID: UUID) -> ManagedSettingsStore.Name {
        ManagedSettingsStore.Name("nag.\(profileID.uuidString)")
    }

    public static func apply(_ profiles: [LockProfile], now: Date) {
        for profile in profiles {
            apply(profile, now: now)
        }
    }

    public static func apply(_ profile: LockProfile, now: Date) {
        let store = ManagedSettingsStore(named: storeName(for: profile.id))
        guard profile.isShielding(at: now), let selection = SelectionCoding.decode(profile.selection) else {
            store.clearAllSettings()
            return
        }
        let apps = selection.applicationTokens
        let categories = selection.categoryTokens
        let domains = selection.webDomainTokens
        store.shield.applications = apps.isEmpty ? nil : apps
        store.shield.applicationCategories = categories.isEmpty ? nil : .specific(categories)
        store.shield.webDomains = domains.isEmpty ? nil : domains
        store.shield.webDomainCategories = categories.isEmpty ? nil : .specific(categories)
        store.application.denyAppRemoval = profile.strict ? true : nil
    }

    public static func clear(profileID: UUID) {
        ManagedSettingsStore(named: storeName(for: profileID)).clearAllSettings()
    }

    /// The lock behind a shield, for the shield screen and its buttons. Falls back to any shielding lock,
    /// since apps blocked through a category don't appear in the selection by token.
    public static func profile(
        in state: NagState,
        now: Date,
        application: ApplicationToken? = nil,
        category: ActivityCategoryToken? = nil,
        webDomain: WebDomainToken? = nil
    ) -> LockProfile? {
        let shielding = state.profiles.filter { $0.isShielding(at: now) }
        let match = shielding.first { profile in
            guard let selection = SelectionCoding.decode(profile.selection) else { return false }
            if let application, selection.applicationTokens.contains(application) { return true }
            if let category, selection.categoryTokens.contains(category) { return true }
            if let webDomain, selection.webDomainTokens.contains(webDomain) { return true }
            return false
        }
        return match ?? shielding.first
    }
}
#endif
