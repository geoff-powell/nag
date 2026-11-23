import AppIntents

struct LockConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Lock"

    @Parameter(title: "Lock") var lock: LockEntity?
}
