import Foundation
import NagKit

/// Launch mode for the UI tests in `NagUITests`.
///
/// Launched with `-NagUITesting`, the app uses a fresh store in a temporary folder seeded with a known
/// set of nags, skips onboarding, and stays off iCloud, notifications and Screen Time, so tests never see or change
/// real data, even on a real iPhone.
/// `NAG_UI_SCENARIO` picks the seed: `sample` (default) or `empty`.
enum UITesting {
    static let launchArgument = "-NagUITesting"

    static var isActive: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains(launchArgument)
        #else
        false
        #endif
    }

    @MainActor
    static func makeModel() -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "NagUITesting-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = SharedStore(directory: directory)
        let scenario = ProcessInfo.processInfo.environment["NAG_UI_SCENARIO"] ?? "sample"
        store.update { $0 = seed(scenario, now: .now, calendar: .current) }
        return AppModel(store: store, isolated: true)
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

        var stretch = NagTask(
            title: "Stretch",
            startAt: calendar.date(byAdding: .day, value: 1, to: now) ?? now,
            repeatRule: .daily,
            now: now.addingTimeInterval(-86_400)
        )
        stretch.lastCompletedAt = now.addingTimeInterval(-3600)

        var taxes = NagTask(title: "File taxes", startAt: now.addingTimeInterval(-3 * 3600), now: now.addingTimeInterval(-86_400))
        taxes.complete(at: now.addingTimeInterval(-2 * 3600), calendar: calendar)

        state.tasks = [meds, plants, stretch, taxes]
        return state
    }
}
