import NagKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var screenTimeError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Notifications", value: notificationLabel)
                    if model.notificationStatus == .notDetermined {
                        Button("Allow notifications") { Task { await model.requestNotifications() } }
                    }
                    LabeledContent("Screen Time", value: model.screenTimeStatus == .approved ? "Allowed" : "Not allowed")
                    if model.screenTimeStatus != .approved {
                        Button("Allow Screen Time access") {
                            Task { screenTimeError = await model.requestScreenTime() }
                        }
                        if let screenTimeError {
                            Text(screenTimeError).font(.footnote).foregroundStyle(.red)
                        }
                    }
                    Button("Open iPhone Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("For nags that cut through Focus, turn on Time Sensitive Notifications for Nag in Settings > Notifications > Nag.")
                }

                Section {
                    Toggle("Quiet hours", isOn: settingBinding(\.quietHours.enabled))
                    if model.state.settings.quietHours.enabled {
                        DatePicker("From", selection: minuteBinding(\.quietHours.startMinute), displayedComponents: .hourAndMinute)
                        DatePicker("Until", selection: minuteBinding(\.quietHours.endMinute), displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    Text("No nags during quiet hours. Anything still due picks up again when they end.")
                }

                Section {
                    Stepper(
                        "Emergency unlocks: \(model.state.settings.emergencyUnlocksPerMonth) a month",
                        value: settingBinding(\.emergencyUnlocksPerMonth),
                        in: 0...10
                    )
                    .disabled(model.state.anyLockEngaged)
                } footer: {
                    Text(model.state.anyLockEngaged
                        ? "Can't be changed while a lock is on."
                        : "Emergency unlocks switch a lock off without meeting its requirements.")
                }

                Section {
                    NavigationLink("Unlock keys") { KeysView() }
                }

                Section {
                    Button("Send a test nag") {
                        Task { await NotificationSync.alert(title: "This is a nag", body: "If you can see this, Nag can reach you.") }
                    }
                } footer: {
                    Text("Nags also sync with Nag on your Mac through iCloud.")
                }
            }
            .navigationTitle("Settings")
            .task { await model.refreshPermissions() }
        }
    }

    private var notificationLabel: String {
        switch model.notificationStatus {
        case .authorized: "Allowed"
        case .denied: "Off — turn on in Settings"
        case .provisional, .ephemeral: "Quiet"
        default: "Not asked yet"
        }
    }

    private func settingBinding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.state.settings[keyPath: keyPath] },
            set: { value in model.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }

    private func minuteBinding(_ keyPath: WritableKeyPath<AppSettings, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minute = model.state.settings[keyPath: keyPath]
                return model.calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now
            },
            set: { date in
                let parts = model.calendar.dateComponents([.hour, .minute], from: date)
                model.updateSettings { $0[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0) }
            }
        )
    }
}
