import AppIntents

struct NagShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateNagIntent(),
            phrases: [
                "Nag me with \(.applicationName)",
                "Add a nag in \(.applicationName)",
                "Create a nag in \(.applicationName)",
                "Add a \(\.$preset) nag in \(.applicationName)",
                "Add an \(\.$preset) nag in \(.applicationName)",
                "Create a \(\.$preset) nag in \(.applicationName)",
                "New \(\.$preset) nag in \(.applicationName)",
            ],
            shortTitle: "Create Nag",
            systemImageName: "bell.badge"
        )
        AppShortcut(
            intent: CompleteNagIntent(),
            phrases: [
                "Mark a nag done in \(.applicationName)",
                "I did it \(.applicationName)",
            ],
            shortTitle: "Complete Nag",
            systemImageName: "checkmark.circle"
        )
        AppShortcut(
            intent: SnoozeNagIntent(),
            phrases: ["Snooze a nag in \(.applicationName)"],
            shortTitle: "Snooze Nag",
            systemImageName: "zzz"
        )
        AppShortcut(
            intent: StartLockIntent(),
            phrases: [
                "Lock my apps with \(.applicationName)",
                "Start a lock in \(.applicationName)",
            ],
            shortTitle: "Start Lock",
            systemImageName: "lock.fill"
        )
        AppShortcut(
            intent: ShowUnlockStepsIntent(),
            phrases: [
                "What do I owe \(.applicationName)",
                "Show my unlock steps in \(.applicationName)",
            ],
            shortTitle: "Unlock Steps",
            systemImageName: "list.bullet"
        )
    }
}
