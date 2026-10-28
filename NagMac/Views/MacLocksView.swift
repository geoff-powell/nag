import AppKit
import NagKit
import SwiftUI
import UniformTypeIdentifiers

struct MacLocksView: View {
    @Environment(MacModel.self) private var model
    @State private var editing: MacLockEditorItem?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            List {
                ForEach(model.state.profiles) { profile in
                    MacLockRow(profile: profile, now: context.date) { editing = .edit(profile) }
                }
            }
            .overlay {
                if model.state.profiles.isEmpty {
                    ContentUnavailableView {
                        Label("No locks yet", systemImage: "lock.open")
                    } description: {
                        Text("Pick the apps that pull you away. Nag hides them while they're locked and shows what it takes to open them.")
                    } actions: {
                        Button("New lock") { editing = .new }
                    }
                }
            }
        }
        .navigationTitle("Locks")
        .toolbar {
            Button("New lock", systemImage: "plus") { editing = .new }
        }
        .sheet(item: $editing) { item in
            MacLockEditor(profile: item.profile)
        }
    }
}

enum MacLockEditorItem: Identifiable {
    case new
    case edit(LockProfile)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let profile): profile.id.uuidString
        }
    }

    var profile: LockProfile? {
        if case .edit(let profile) = self { return profile }
        return nil
    }
}

private struct MacLockRow: View {
    let profile: LockProfile
    let now: Date
    let onEdit: () -> Void
    @Environment(MacModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: profile.symbol)
                .font(.title2)
                .foregroundStyle(profile.isShielding(at: now) ? .orange : .secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(profile.name).font(.headline)
                    MacStatusPill(profile: profile, now: now)
                    if profile.strict { Text("Strict").font(.caption).foregroundStyle(.secondary) }
                }
                HStack(spacing: 4) {
                    ForEach(profile.blockedApps.prefix(8)) { app in
                        Image(nsImage: app.icon).resizable().frame(width: 18, height: 18).help(app.name)
                    }
                    if profile.blockedApps.isEmpty {
                        Text("No apps chosen").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing) {
                switch profile.status {
                case .off:
                    Button("Lock now") { model.lockNow(profile.id) }
                        .disabled(profile.blockedApps.isEmpty)
                    Button("Edit…", action: onEdit)
                case .locked:
                    Button("Unlock…") { model.showUnlock(profile.id) }
                case .unlocked:
                    Button("Lock again now") { model.relockNow(profile.id) }
                }
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Edit…", action: onEdit).disabled(profile.isEngaged)
            Button("Delete", role: .destructive) { model.deleteProfile(profile.id) }
                .disabled(profile.isEngaged)
        }
    }

    private var detail: String {
        var parts = [profile.requirements.isEmpty
            ? "No requirements: only an emergency unlock opens it"
            : profile.requirements.map { UnlockEvaluator.title(for: $0.kind, state: model.state) }.joined(separator: " + ")]
        if let schedule = profile.schedule { parts.append(schedule.label) }
        if profile.lockWhileNagsDue { parts.append("Locks while nags are due") }
        return parts.joined(separator: " · ")
    }
}

struct MacLockEditor: View {
    @Environment(MacModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let isNew: Bool
    @State private var profile: LockProfile
    @State private var apps: [BlockedApp]
    @State private var addingRequirement = false

    static let symbols = ["lock.fill", "bubble.left.and.bubble.right.fill", "play.tv.fill", "gamecontroller.fill", "cart.fill", "newspaper.fill", "moon.fill", "briefcase.fill", "safari.fill"]

    init(profile: LockProfile?) {
        isNew = profile == nil
        let initial = profile ?? LockProfile(name: "")
        _profile = State(initialValue: initial)
        _apps = State(initialValue: initial.blockedApps)
    }

    private var isEngaged: Bool { model.profile(profile.id)?.isEngaged == true }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if isEngaged {
                    Label("This lock is on. Unlock it to make changes.", systemImage: "lock.fill")
                        .foregroundStyle(.orange)
                }
                Group {
                    Section {
                        TextField("Name", text: $profile.name)
                        Picker("Icon", selection: $profile.symbol) {
                            ForEach(Self.symbols, id: \.self) { Image(systemName: $0).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    appsSection
                    requirementsSection
                    Section("After unlocking") {
                        Toggle("Unlock automatically when requirements are met", isOn: $profile.autoUnlock)
                        if profile.hasSessionBoundRequirements {
                            Picker("Stay open for", selection: $profile.unlockMinutes) {
                                ForEach([15, 30, 60, 120, 240] as [Int?] + [nil], id: \.self) { minutes in
                                    Text(minutes.map(NagFormat.minutes) ?? "Until I lock it again").tag(minutes)
                                }
                            }
                        }
                    }
                    scheduleSection
                    Section {
                        Toggle("Lock while nags are due", isOn: $profile.lockWhileNagsDue)
                            .onChange(of: profile.lockWhileNagsDue) { _, on in
                                if on, !profile.requirements.contains(where: { $0.kind == .clearDueNags }) {
                                    profile.requirements.append(UnlockRequirement(kind: .clearDueNags))
                                }
                            }
                        Toggle("Strict mode", isOn: $profile.strict)
                    } footer: {
                        Text("Strict mode quits blocked apps instead of hiding them, and Nag refuses to quit while the lock is on.")
                            .foregroundStyle(.secondary)
                    }
                    Section("Message") {
                        TextField("Shown when a blocked app is opened", text: $profile.message, axis: .vertical)
                    }
                }
                .disabled(isEngaged)
            }
            .formStyle(.grouped)

            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        model.deleteProfile(profile.id)
                        dismiss()
                    }
                    .disabled(isEngaged)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    profile.name = profile.name.trimmingCharacters(in: .whitespaces)
                    profile.blockedApps = apps
                    if let schedule = profile.schedule, !schedule.isValid { profile.schedule = nil }
                    model.saveProfile(profile)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isEngaged || profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 560, height: 680)
        .sheet(isPresented: $addingRequirement) {
            MacRequirementDraft { profile.requirements.append($0) }
        }
    }

    private var appsSection: some View {
        Section("Block these apps") {
            ForEach(apps) { app in
                HStack {
                    Image(nsImage: app.icon).resizable().frame(width: 20, height: 20)
                    Text(app.name)
                    Spacer()
                    Button {
                        apps.removeAll { $0.id == app.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Button("Choose apps…", action: chooseApps)
                Menu("Running apps") {
                    ForEach(runningApps) { app in
                        Button(app.name) { add(app) }
                    }
                }
                .fixedSize()
            }
        }
    }

    private var runningApps: [BlockedApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(BlockedApp.init(running:))
            .filter { BlockedApp.isBlockable($0.bundleID) && !apps.contains($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(filePath: "/Applications")
        panel.prompt = "Block"
        guard panel.runModal() == .OK else { return }
        panel.urls.compactMap(BlockedApp.init(url:)).forEach(add)
    }

    private func add(_ app: BlockedApp) {
        guard BlockedApp.isBlockable(app.bundleID), !apps.contains(where: { $0.id == app.id }) else { return }
        apps.append(app)
    }

    private var requirementsSection: some View {
        Section {
            ForEach(profile.requirements) { requirement in
                HStack {
                    Text(UnlockEvaluator.title(for: requirement.kind, state: model.state))
                    if requirement.kind.isPhoneOnly {
                        Text("Only available on iPhone").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        profile.requirements.removeAll { $0.id == requirement.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Add requirement…") { addingRequirement = true }
        } header: {
            Text("To unlock")
        } footer: {
            Text(profile.requirements.isEmpty ? "With no requirements, only an emergency unlock opens it." : "All of these are needed.")
                .foregroundStyle(.secondary)
        }
    }

    private var scheduleSection: some View {
        Section("Schedule") {
            Toggle("Lock on a schedule", isOn: Binding(
                get: { profile.schedule != nil },
                set: { profile.schedule = $0 ? LockSchedule() : nil }
            ))
            if profile.schedule != nil {
                DatePicker("From", selection: minuteBinding(\.startMinute), displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: minuteBinding(\.endMinute), displayedComponents: .hourAndMinute)
                HStack {
                    ForEach(1...7, id: \.self) { day in
                        Toggle(model.calendar.shortWeekdaySymbols[day - 1], isOn: Binding(
                            get: { profile.schedule?.weekdays.contains(day) == true },
                            set: { on in
                                if on { profile.schedule?.weekdays.insert(day) } else { profile.schedule?.weekdays.remove(day) }
                            }
                        ))
                        .toggleStyle(.button)
                    }
                }
                if let schedule = profile.schedule, !schedule.isValid {
                    Text("Pick at least one day and a window of 15 minutes or more.").foregroundStyle(.red)
                }
            }
        }
    }

    private func minuteBinding(_ keyPath: WritableKeyPath<LockSchedule, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minute = profile.schedule?[keyPath: keyPath] ?? 0
                return model.calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now
            },
            set: { date in
                let parts = model.calendar.dateComponents([.hour, .minute], from: date)
                profile.schedule?[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }
}

extension UnlockRequirement.Kind {
    /// Requirements the Mac can't check: no pedometer, no NFC or camera key scans.
    var isPhoneOnly: Bool {
        switch self {
        case .walk, .scanKey: true
        default: false
        }
    }
}

private struct MacRequirementDraft: View {
    enum Kind: String, CaseIterable, Identifiable {
        case tasks = "Finish specific nags"
        case clear = "Clear every due nag"
        case wait = "Wait it out"
        case phrase = "Type a commitment"
        var id: String { rawValue }
    }

    let onAdd: (UnlockRequirement) -> Void
    @Environment(MacModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var kind: Kind = .tasks
    @State private var taskIDs: Set<UUID> = []
    @State private var minutes = 10
    @State private var phrase = "I'm choosing distraction over what I said I'd do."

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Requirement", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                switch kind {
                case .tasks:
                    Section("Nags") {
                        ForEach(model.state.tasks.filter { !$0.isFinished }) { task in
                            Toggle(task.title, isOn: Binding(
                                get: { taskIDs.contains(task.id) },
                                set: { if $0 { taskIDs.insert(task.id) } else { taskIDs.remove(task.id) } }
                            ))
                        }
                    }
                case .clear:
                    Text("Every nag that's due has to be done. Snoozing doesn't count.")
                        .foregroundStyle(.secondary)
                case .wait:
                    Stepper(NagFormat.minutes(minutes), value: $minutes, in: 1...120)
                case .phrase:
                    TextField("Phrase", text: $phrase, axis: .vertical)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    if let requirement { onAdd(requirement) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(requirement == nil)
            }
            .padding()
        }
        .frame(width: 440, height: 420)
    }

    private var requirement: UnlockRequirement? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: UnlockRequirement.Kind? = switch self.kind {
        case .tasks: taskIDs.isEmpty ? nil : .completeTasks(model.state.tasks.map(\.id).filter(taskIDs.contains))
        case .clear: .clearDueNags
        case .wait: .wait(minutes: minutes)
        case .phrase: trimmed.isEmpty ? nil : .typePhrase(trimmed)
        }
        return kind.map { UnlockRequirement(kind: $0) }
    }
}
