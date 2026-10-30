import NagKit
import SwiftUI

struct MacSettingsView: View {
    @Environment(MacModel.self) private var model
    @AppStorage(NagPanelController.showPanelKey) private var showNagPanel = true
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Notifications", value: notificationLabel)
                HStack {
                    if model.notificationStatus == .notDetermined {
                        Button("Allow notifications") { Task { await model.requestNotifications() } }
                    }
                    Button("Open Notification Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Send a test nag") {
                        Task { await NotificationSync.alert(title: "This is a nag", body: "If you can see this, Nag can reach you.") }
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Set Nag's alert style to Persistent in System Settings so nags stay on screen until you deal with them.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show the nag panel while nags are due", isOn: $showNagPanel)
                    .onChange(of: showNagPanel) { model.tick() }
                Toggle("Open at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { loginError = model.setLaunchAtLogin($0) }
                ))
                if let loginError {
                    Text(loginError).foregroundStyle(.red)
                }
            } header: {
                Text("On this Mac")
            } footer: {
                Text("The nag panel sits in the corner of the screen until everything due is done. Open at login keeps locks working after a restart.")
                    .foregroundStyle(.secondary)
            }

            Section("Quiet hours") {
                Toggle("Quiet hours", isOn: settingBinding(\.quietHours.enabled))
                if model.state.settings.quietHours.enabled {
                    DatePicker("From", selection: minuteBinding(\.quietHours.startMinute), displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: minuteBinding(\.quietHours.endMinute), displayedComponents: .hourAndMinute)
                }
            }

            Section {
                Picker("Nag tone", selection: settingBinding(\.nagTone)) {
                    ForEach(NagTone.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } footer: {
                Text(model.state.settings.nagTone.explanation)
                    .foregroundStyle(.secondary)
            }

            Section {
                Stepper(
                    "Emergency unlocks: \(model.state.settings.emergencyUnlocksPerMonth) a month",
                    value: settingBinding(\.emergencyUnlocksPerMonth),
                    in: 0...10
                )
                .disabled(model.state.anyLockEngaged)
            } footer: {
                Text(model.state.anyLockEngaged ? "Can't be changed while a lock is on." : "")
                    .foregroundStyle(.secondary)
            }

            MCPSettingsSection()

            Section {
                Label("Nags sync with Nag on your iPhone through iCloud. Locks and settings stay on each device.", systemImage: "icloud")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task { await model.refreshPermissions() }
    }

    private var notificationLabel: String {
        switch model.notificationStatus {
        case .authorized: "Allowed"
        case .denied: "Off — turn on in System Settings"
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
