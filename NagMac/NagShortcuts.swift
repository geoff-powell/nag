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
    }
}
