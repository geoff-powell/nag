import Darwin
import Foundation
import NagKit
import Synchronization

/// Launch mode for the UI tests in `NagMacUITests`.
///
/// Launched with `-NagUITesting`, the Mac app uses a fresh store in a temporary folder seeded with a
/// known set of nags, and stays off iCloud, notifications, the HTTP MCP server and launch-at-login, so
/// tests never see or change real data. `NAG_UI_SCENARIO` picks the seed: `sample` (default) or `empty`.
enum MacUITesting {
    static let launchArgument = "-NagUITesting"

    static var isActive: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains(launchArgument)
        #else
        false
        #endif
    }

    @MainActor
    static func makeModel() -> MacModel {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "NagUITesting-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = SharedStore(directory: directory)
        let scenario = ProcessInfo.processInfo.environment["NAG_UI_SCENARIO"] ?? "sample"
        store.update { $0 = seed(scenario, now: .now, calendar: .current) }
        return MacModel(store: store, isolated: true)
    }

    static func seed(_ scenario: String, now: Date, calendar: Calendar) -> NagState {
        var state = NagState()
        state.settings.hasOnboarded = true
        guard scenario == "sample" else { return state }

        var meds = NagTask(
            title: "Take meds",
            notes: "With breakfast",
            startAt: now.addingTimeInterval(-20 * 60),
            repeatRule: .daily,
            now: now.addingTimeInterval(-86_400)
        )
        meds.style.maxSnoozes = 3

        let plants = NagTask(title: "Water the plants", startAt: now.addingTimeInterval(2 * 3600), now: now)

        var taxes = NagTask(title: "File taxes", startAt: now.addingTimeInterval(-3 * 3600), now: now.addingTimeInterval(-86_400))
        taxes.complete(at: now.addingTimeInterval(-2 * 3600), calendar: calendar)

        state.tasks = [meds, plants, taxes]
        return state
    }

    // MARK: - Usage reports

    /// Where to write usage reports, set by the tests. The test runner is sandboxed, so it can't inspect
    /// Nag's process itself; Nag reports on itself instead.
    static let usageReportEnvironmentKey = "NAG_UI_USAGE_REPORT"

    /// Writes CPU time, memory footprint and main-thread lag to a JSON file every half second, from a
    /// background queue so reports keep coming even if the main thread is stuck.
    static func startReportingUsage() {
        guard isActive, let path = ProcessInfo.processInfo.environment[usageReportEnvironmentKey] else { return }
        UsageReporter.shared.start(url: URL(filePath: path))
    }
}

private final class UsageReporter: Sendable {
    static let shared = UsageReporter()

    private let lastMainThreadPing = Mutex(ProcessInfo.processInfo.systemUptime)
    private let queue = DispatchQueue(label: "Nag.UsageReporter")
    private let timers = Mutex<[any DispatchSourceTimer]>([])

    func start(url: URL) {
        let ping = DispatchSource.makeTimerSource(queue: .main)
        ping.schedule(deadline: .now(), repeating: .milliseconds(100))
        ping.setEventHandler { [self] in
            lastMainThreadPing.withLock { $0 = ProcessInfo.processInfo.systemUptime }
        }
        let report = DispatchSource.makeTimerSource(queue: queue)
        report.schedule(deadline: .now(), repeating: .milliseconds(500))
        report.setEventHandler { [self] in write(to: url) }
        timers.withLock { $0 = [ping, report] }
        ping.resume()
        report.resume()
    }

    private func write(to url: URL) {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = Double(info.ri_user_time + info.ri_system_time)
        let now = ProcessInfo.processInfo.systemUptime
        let report: [String: Double] = [
            "cpuSeconds": ticks * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000,
            "footprintBytes": Double(info.ri_phys_footprint),
            "uptime": now,
            "mainThreadLag": now - lastMainThreadPing.withLock { $0 },
        ]
        guard let data = try? JSONEncoder().encode(report) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
