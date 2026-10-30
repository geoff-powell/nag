import NagKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var screenTimeError: String?
    @State private var showVersion = false
    @State private var titleScrolledAway = false

    var body: some View {
        NavigationStack {
            Form {
                Section {} header: { title }
                    .listSectionSpacing(.compact)

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
            // The large title is drawn in the form instead (see `title`), because the system one can't take
            // gestures. The inline title fades in once it scrolls away, like the system large title.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Settings")
                        .font(.headline)
                        .opacity(titleScrolledAway ? 1 : 0)
                        .accessibilityHidden(!titleScrolledAway)
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 40
            } action: { _, scrolledAway in
                withAnimation(.easeInOut(duration: 0.2)) { titleScrolledAway = scrolledAway }
            }
            .task { await model.refreshPermissions() }
        }
    }

    /// Looks like a large navigation title. Long-press it to show the app version underneath.
    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(.largeTitle.bold())
                .foregroundStyle(Color.primary)
            if showVersion {
                Text(versionLabel)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .transition(.opacity)
            }
        }
        .textCase(nil)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Line up with where the system large title would sit.
        .padding(.leading, -16)
        .padding(.top, -18)
        .contentShape(Rectangle())
        .onLongPressGesture {
            withAnimation { showVersion.toggle() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityAction(named: showVersion ? "Hide version" : "Show version") {
            withAnimation { showVersion.toggle() }
        }
        .accessibilityIdentifier("settings.title")
    }

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (\(build))"
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
