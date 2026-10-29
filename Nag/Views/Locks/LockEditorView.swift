@preconcurrency import FamilyControls
import NagKit
import SwiftUI

struct LockEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let isNew: Bool
    @State private var profile: LockProfile
    @State private var selection: FamilyActivitySelection
    @State private var showPicker = false
    @State private var addingRequirement: RequirementDraft.Kind?
    @State private var confirmDelete = false

    static let symbols = ["lock.fill", "iphone.slash", "bubble.left.and.bubble.right.fill", "play.tv.fill", "gamecontroller.fill", "cart.fill", "moon.fill", "briefcase.fill", "book.fill", "sunrise.fill"]
    static let unlockDurations: [Int?] = [15, 30, 60, 120, 240, nil]

    init(profile: LockProfile?) {
        isNew = profile == nil
        let initial = profile ?? LockProfile(name: "")
        _profile = State(initialValue: initial)
        _selection = State(initialValue: SelectionCoding.decode(initial.selection) ?? FamilyActivitySelection())
    }

    /// Engaged locks can't be edited, or editing would be a way out.
    private var isEngaged: Bool {
        model.profile(profile.id)?.isEngaged == true
    }

    var body: some View {
        NavigationStack {
            Form {
                if isEngaged {
                    Section {
                        Label("This lock is on. Unlock it to make changes.", systemImage: "lock.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Group {
                    Section {
                        TextField("Name, e.g. Social media", text: $profile.name)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(Self.symbols, id: \.self) { symbol in
                                    Button {
                                        profile.symbol = symbol
                                    } label: {
                                        Image(systemName: symbol)
                                            .frame(width: 36, height: 36)
                                            .background(profile.symbol == symbol ? Color.orange.opacity(0.2) : .clear, in: Circle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    Section("Block") {
                        Button {
                            showPicker = true
                        } label: {
                            LabeledContent("Apps and websites", value: SelectionCoding.summary(of: selection).label)
                        }
                    }

                    requirementsSection

                    Section {
                        Toggle("Unlock automatically", isOn: $profile.autoUnlock)
                        if profile.hasSessionBoundRequirements {
                            Picker("Stay open for", selection: $profile.unlockMinutes) {
                                ForEach(Self.unlockDurations, id: \.self) { minutes in
                                    Text(minutes.map(NagFormat.minutes) ?? "Until I lock it again").tag(minutes)
                                }
                            }
                        }
                    } header: {
                        Text("After unlocking")
                    } footer: {
                        Text(profile.hasSessionBoundRequirements
                            ? "Unlocking automatically opens the apps as soon as nags are done or the timer runs out. After the time's up the lock comes back and has to be earned again."
                            : "Unlocking automatically opens the apps as soon as the nags are done.")
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
                        Text("Lock while nags are due switches this lock on whenever anything's due, until you clear it. Strict mode stops apps from being deleted while locked.")
                    }

                    Section("Message on the lock screen") {
                        TextField("Message", text: $profile.message, axis: .vertical)
                            .lineLimit(2...4)
                    }
                }
                .disabled(isEngaged)

                if !isNew {
                    Section {
                        Button("Delete lock", role: .destructive) { confirmDelete = true }
                            .disabled(isEngaged)
                    }
                }
            }
            .navigationTitle(isNew ? "New lock" : "Edit lock")
            .navigationBarTitleDisplayMode(.inline)
            .familyActivityPicker(isPresented: $showPicker, selection: $selection)
            .sheet(item: $addingRequirement) { kind in
                RequirementDraftView(kind: kind) { requirement in
                    profile.requirements.append(requirement)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isEngaged || profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Delete this lock?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    model.deleteProfile(profile.id)
                    dismiss()
                }
            }
        }
    }

    private var requirementsSection: some View {
        Section {
            ForEach(profile.requirements) { requirement in
                Label(UnlockEvaluator.title(for: requirement.kind, state: model.state), systemImage: requirement.kind.symbol)
            }
            .onDelete { profile.requirements.remove(atOffsets: $0) }

            Menu {
                ForEach(RequirementDraft.Kind.allCases) { kind in
                    Button(kind.label, systemImage: kind.symbol) {
                        if kind == .clearDueNags {
                            profile.requirements.append(UnlockRequirement(kind: .clearDueNags))
                        } else {
                            addingRequirement = kind
                        }
                    }
                    .disabled(kind == .scanKey && model.state.keys.isEmpty)
                }
            } label: {
                Label("Add requirement", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("To unlock")
        } footer: {
            Text(profile.requirements.isEmpty
                ? "With no requirements, the only way out is an emergency unlock."
                : "All of these are needed to unlock.")
        }
    }

    private var scheduleSection: some View {
        Section {
            Toggle("Lock on a schedule", isOn: Binding(
                get: { profile.schedule != nil },
                set: { profile.schedule = $0 ? LockSchedule() : nil }
            ))
            if profile.schedule != nil {
                DatePicker("From", selection: minuteBinding(\.startMinute), displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: minuteBinding(\.endMinute), displayedComponents: .hourAndMinute)
                WeekdayPicker(selection: Binding(
                    get: { profile.schedule?.weekdays ?? [] },
                    set: { profile.schedule?.weekdays = $0 }
                ))
            }
        } header: {
            Text("Schedule")
        } footer: {
            if let schedule = profile.schedule, !schedule.isValid {
                Text("Pick at least one day, and a window of 15 minutes or more.")
                    .foregroundStyle(.red)
            } else if profile.schedule != nil {
                Text("Switches on at the start of each window. Earning an unlock keeps it open for the rest of that window.")
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

    private func save() {
        profile.name = profile.name.trimmingCharacters(in: .whitespaces)
        profile.selection = SelectionCoding.encode(selection)
        profile.selectionSummary = SelectionCoding.summary(of: selection)
        if let schedule = profile.schedule, !schedule.isValid { profile.schedule = nil }
        model.saveProfile(profile)
        dismiss()
    }
}

struct WeekdayPicker: View {
    @Binding var selection: Set<Int>
    @Environment(\.calendar) private var calendar

    var body: some View {
        let ordered = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        HStack {
            ForEach(ordered, id: \.self) { day in
                let isOn = selection.contains(day)
                Button(calendar.veryShortWeekdaySymbols[day - 1]) {
                    withAnimation(Motion.quick) {
                        if isOn { selection.remove(day) } else { selection.insert(day) }
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(isOn ? Color.orange : Color.secondary.opacity(0.15), in: Circle())
                .foregroundStyle(isOn ? .white : .primary)
                .accessibilityLabel(calendar.weekdaySymbols[day - 1])
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

extension UnlockRequirement.Kind {
    var symbol: String {
        switch self {
        case .completeTasks: "checklist"
        case .clearDueNags: "bell.slash.fill"
        case .scanKey: "wave.3.right"
        case .walk: "figure.walk"
        case .wait: "hourglass"
        case .typePhrase: "keyboard"
        }
    }
}
