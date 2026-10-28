import AppKit
import NagKit

/// An app a Mac lock blocks. Stored as JSON in `LockProfile.selection`.
struct BlockedApp: Codable, Hashable, Identifiable {
    var bundleID: String
    var name: String

    var id: String { bundleID }

    var icon: NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }

    init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }

    init?(url: URL) {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return nil }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        self.init(bundleID: bundleID, name: name)
    }

    init?(running app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return nil }
        self.init(bundleID: bundleID, name: app.localizedName ?? bundleID)
    }

    /// Apps that are never blocked: Nag itself and what's needed to use the Mac at all.
    static let neverBlocked: Set<String> = [
        "com.apple.finder", "com.apple.systempreferences", "com.apple.Settings", "com.apple.loginwindow",
        "com.apple.dock", "com.apple.ActivityMonitor", "com.apple.Terminal",
    ]

    static func isBlockable(_ bundleID: String) -> Bool {
        bundleID != Bundle.main.bundleIdentifier && !neverBlocked.contains(bundleID)
    }
}

extension LockProfile {
    var blockedApps: [BlockedApp] {
        get { (try? JSONDecoder().decode([BlockedApp].self, from: selection)) ?? [] }
        set {
            selection = (try? JSONEncoder().encode(newValue)) ?? Data()
            selectionSummary = SelectionSummary(apps: newValue.count)
        }
    }
}
