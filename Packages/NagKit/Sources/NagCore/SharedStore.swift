import Foundation
import notify

/// JSON state shared by the app and its extensions, in the app group container.
///
/// Every change is a locked read-modify-write, because the app, the DeviceActivity monitor and the shield
/// extensions run as separate processes. After writing, a Darwin notification tells the others to reload.
public final class SharedStore: @unchecked Sendable {
    public let directory: URL
    public let groupID: String?

    private var fileURL: URL { directory.appending(path: "state.json") }
    private var lockURL: URL { directory.appending(path: "state.lock") }
    /// The completion history, kept apart from the nags so extensions that only need the nags never read it.
    private var historyURL: URL { directory.appending(path: "history.json") }

    public init(directory: URL, groupID: String? = nil) {
        self.directory = directory
        self.groupID = groupID
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The store located through the `NagAppGroup` Info.plist key. Falls back to Application Support
    /// when the app group isn't available (for example an unsigned simulator build).
    public static let shared: SharedStore = {
        let groupID = Bundle.main.object(forInfoDictionaryKey: NagID.appGroupInfoKey) as? String
        if let groupID, !groupID.isEmpty, !groupID.contains("$("),
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            return SharedStore(directory: container.appending(path: "Nag", directoryHint: .isDirectory), groupID: groupID)
        }
        return SharedStore(directory: URL.applicationSupportDirectory.appending(path: "Nag", directoryHint: .isDirectory))
    }()

    public var changeNotificationName: String {
        "\(groupID ?? "nag.local").state-changed"
    }

    public func load() -> NagState {
        withFileLock { read() }
    }

    /// This device's completion history. Not synced: each device keeps its own.
    public func loadHistory() -> CompletionHistory {
        withFileLock { readHistory() }
    }

    /// Reads the latest state, applies `body`, and writes the result if it changed. Completions and
    /// undos in the change are logged to the completion history, whichever process made them.
    /// Don't call `load` or `update` from inside `body`: the lock isn't reentrant.
    @discardableResult
    public func update<T>(_ body: (inout NagState) throws -> T) rethrows -> T {
        var changed = false
        let result = try withFileLock {
            var state = read()
            let before = state
            let result = try body(&state)
            if state != before {
                write(state)
                logCompletions(from: before, to: state)
                changed = true
            }
            return result
        }
        if changed { notify_post(changeNotificationName) }
        return result
    }

    /// Calls `handler` on the main queue whenever another process (or this one) changes the state.
    public func observeChanges(_ handler: @escaping @Sendable () -> Void) -> ChangeObservation {
        var token: Int32 = 0
        notify_register_dispatch(changeNotificationName, &token, .main) { _ in handler() }
        return ChangeObservation(token: token)
    }

    public final class ChangeObservation: @unchecked Sendable {
        private let token: Int32
        init(token: Int32) { self.token = token }
        deinit { notify_cancel(token) }
    }

    private func read() -> NagState {
        guard let data = try? Data(contentsOf: fileURL) else { return NagState() }
        do {
            return try JSONDecoder().decode(NagState.self, from: data)
        } catch {
            // Keep unreadable data instead of silently overwriting it on the next write.
            let backup = directory.appending(path: "state-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? data.write(to: backup)
            return NagState()
        }
    }

    private func write(_ state: NagState) {
        writeJSON(state, to: fileURL)
    }

    private func writeJSON(_ value: some Encodable, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        // Extensions can run while the phone is locked, so the file must stay readable after first unlock.
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func logCompletions(from before: NagState, to after: NagState) {
        let changes = CompletionHistory.changes(from: before, to: after)
        guard !changes.isEmpty else { return }
        var history = readHistory()
        history.apply(changes)
        history.prune(now: Date(), calendar: .current)
        writeJSON(history, to: historyURL)
    }

    private func readHistory() -> CompletionHistory {
        guard let data = try? Data(contentsOf: historyURL) else { return CompletionHistory() }
        do {
            return try JSONDecoder().decode(CompletionHistory.self, from: data)
        } catch {
            let backup = directory.appending(path: "history-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? data.write(to: backup)
            return CompletionHistory()
        }
    }

    private func withFileLock<T>(_ body: () throws -> T) rethrows -> T {
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return try body() }
        flock(descriptor, LOCK_EX)
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        return try body()
    }
}
