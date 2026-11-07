import NagKit
import SwiftUI

struct TaskEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let isNew: Bool
    private let original: NagTask?
    @State private var task: NagTask
    @State private var startNow: Bool
    @State private var showMore = false
    @State private var confirmDelete = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(task: NagTask?) {
        self.init(task: task ?? NagTask(title: ""), original: task, startNow: task == nil)
    }

    /// Reviews a nag from a link before saving it.
    init(draft: NagDraft) {
        self.init(task: draft.task, original: draft.original, startNow: false)
    }

    private init(task: NagTask, original: NagTask?, startNow: Bool) {
        isNew = original == nil
        self.original = original
        _task = State(initialValue: task)
        _startNow = State(initialValue: startNow)
    }

    private var isCustom: Bool { task.repeatRule == .custom }
    private var selectedPreset: NagPreset? { NagPreset.matching(task, keys: model.state.keys) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What needs doing?", text: $task.title)
                        .font(.headline)
                    TextField("Notes, or the first tiny step", text: $task.notes, axis: .vertical)
                        .lineLimit(1...4)
                }

                if task.source != nil || task.link != nil {
                    Section {
                        if let source = task.source {
                            LabeledContent("From", value: source)
                        }
                        if let link = task.link {
                            Link("Open original", destination: link)
                        }
                    }
                }

                Section {
                    // A Grid, not a LazyVGrid, so cards in a row share the tallest card's height.
                    Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                        ForEach(presetRows, id: \.first?.id) { row in
                            GridRow {
                                ForEach(row) { preset in
                                    PresetCard(preset: preset, isSelected: preset == selectedPreset) {
                                        withAnimation(Motion.quick) {
                                            preset.apply(to: &task, keys: model.state.keys, now: .now, calendar: model.calendar)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } header: {
                    Text("Start from")
                } footer: {
                    if selectedPreset == nil {
                        Text("Custom settings. Tap a preset to start over.")
                    }
                }

                Section {
                    if !isCustom {
                        Toggle("Start nagging now", isOn: $startNow.animation(Motion.quick))
                        if !startNow {
                            DatePicker("Starts", selection: $task.startAt)
                        }
                    }
                    Picker("Repeat", selection: $task.repeatRule.animation(Motion.list)) {
                        ForEach(RepeatRule.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .accessibilityIdentifier("repeat")
                    if task.repeatRule == .everyNDays {
                        Stepper("Every \(task.repeatEvery) days", value: $task.repeatEvery, in: 1...365)
                    }
                    if task.repeatRule == .monthly {
                        Picker("On day", selection: $task.monthDay) {
                            ForEach(1...31, id: \.self) { Text("\($0)").tag($0) }
                        }
                    }
                } header: {
                    Text("When")
                } footer: {
                    if task.repeatRule == .monthly {
                        Text("Months without that day use their last day.")
                    }
                }

                if isCustom {
                    timesSection
                }

                Section {
                    Picker("Nag every", selection: $task.style.intervalMinutes) {
                        ForEach(NagStyleChoices.minutes(NagStyleChoices.intervals, including: task.style.intervalMinutes), id: \.self) {
                            Text(NagFormat.minutes($0)).tag($0)
                        }
                    }
                    Picker("Escalation", selection: $task.style.escalation) {
                        ForEach(Escalation.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Snoozes allowed", selection: $task.style.maxSnoozes) {
                        ForEach(NagStyleChoices.snoozeLimits(including: task.style.maxSnoozes), id: \.self) {
                            Text(NagStyleChoices.snoozeLimitLabel($0)).tag($0)
                        }
                    }
                    if !model.state.keys.isEmpty {
                        Picker("To finish", selection: proofBinding) {
                            Text("Tap Done").tag(UUID?.none)
                            ForEach(model.state.keys) { key in
                                Text("Scan \(key.name)").tag(UUID?.some(key.id))
                            }
                        }
                    }
                } header: {
                    Text("Nagging")
                } footer: {
                    Text("Snoozed nags still count as due for locks.")
                }

                Section {
                    DisclosureGroup("More options", isExpanded: $showMore.animation(Motion.quick)) {
                        Picker("Snooze for", selection: $task.style.snoozeMinutes) {
                            ForEach(NagStyleChoices.minutes(NagStyleChoices.snoozeLengths, including: task.style.snoozeMinutes), id: \.self) {
                                Text(NagFormat.minutes($0)).tag($0)
                            }
                        }
                        Picker("Tone", selection: $task.style.tone) {
                            Text("Use the default").tag(NagTone?.none)
                            ForEach(NagTone.allCases, id: \.self) { Text($0.label).tag(NagTone?.some($0)) }
                        }
                        Picker("Working time", selection: $task.style.workMinutes) {
                            ForEach(NagStyleChoices.minutes(NagStyleChoices.workLengths, including: task.style.workMinutes), id: \.self) {
                                Text(NagFormat.minutes($0)).tag($0)
                            }
                        }
                        Toggle("Break through Focus", isOn: $task.style.breakThroughFocus)
                    }
                } footer: {
                    if showMore {
                        Text(moreOptionsFooter)
                    }
                }

                if !isNew {
                    Section {
                        Button("Delete nag", role: .destructive) { confirmDelete = true }
                            .disabled(!model.canDeleteTask(task.id))
                    } footer: {
                        if !model.canDeleteTask(task.id) {
                            Text("A lock is waiting on this nag, so it can't be deleted until that lock is off.")
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New nag" : "Edit nag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(task.title.trimmingCharacters(in: .whitespaces).isEmpty || !task.hasValidSchedule)
                }
            }
            .onChange(of: task.repeatRule) { _, rule in
                if rule == .custom, task.times.isEmpty {
                    task.times = [NagTime(minute: minuteOfDay(task.startAt))]
                }
            }
            .confirmationDialog("Delete this nag?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    model.deleteTask(task.id)
                    dismiss()
                }
            }
        }
    }

    /// Two cards per row, or one at accessibility text sizes.
    private var presetRows: [[NagPreset]] {
        let columns = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return stride(from: 0, to: NagPreset.all.count, by: columns).map {
            Array(NagPreset.all[$0..<min($0 + columns, NagPreset.all.count)])
        }
    }

    private var moreOptionsFooter: String {
        let working = "Working time is how long Nag stays quiet after you tap Started."
        guard model.state.keys.isEmpty else { return working }
        return working + " To require a scan to finish, pair an NFC tag or QR code in Settings > Unlock keys."
    }

    private var proofBinding: Binding<UUID?> {
        Binding(
            get: { task.proof.keyID },
            set: { task.proof = $0.map(CompletionProof.scanKey) ?? .none }
        )
    }

    private var timesSection: some View {
        Section {
            ForEach($task.times) { $time in
                VStack(alignment: .leading, spacing: 10) {
                    DatePicker("Time", selection: minuteBinding($time.minute), displayedComponents: .hourAndMinute)
                    WeekdayPicker(selection: $time.weekdays)
                }
                .padding(.vertical, 4)
            }
            .onDelete { offsets in
                withAnimation(Motion.list) { task.times.remove(atOffsets: offsets) }
            }
            Button("Add time", systemImage: "plus") {
                withAnimation(Motion.list) {
                    task.times.append(NagTime(minute: task.times.last.map { ($0.minute + 60) % 1440 } ?? 9 * 60))
                }
            }
        } header: {
            Text("Times")
        } footer: {
            Group {
                if !task.hasValidSchedule {
                    Text("Add at least one time, and pick at least one day for each.")
                        .foregroundStyle(.red)
                } else {
                    Text("Nags at each time on its days. Swipe a time to remove it.")
                }
            }
            .animation(Motion.quick, value: task.hasValidSchedule)
        }
    }

    private func minuteOfDay(_ date: Date) -> Int {
        let parts = model.calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 9) * 60 + (parts.minute ?? 0)
    }

    private func minuteBinding(_ minute: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                model.calendar.date(bySettingHour: minute.wrappedValue / 60, minute: minute.wrappedValue % 60, second: 0, of: .now) ?? .now
            },
            set: { minute.wrappedValue = minuteOfDay($0) }
        )
    }

    private func save() {
        if startNow && isNew && !isCustom { task.startAt = .now }
        task.alignStartToSchedule(previous: original, now: .now, calendar: model.calendar)
        model.saveTask(task)
        dismiss()
    }
}

/// A preset as a tappable card. The whole card is the tap target, and it shows when the nag's
/// settings match the preset.
private struct PresetCard: View {
    let preset: NagPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: preset.symbol)
                        .font(.title3)
                        .foregroundStyle(.tint)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                }
                .accessibilityHidden(true)
                Text(preset.name)
                    .font(.headline)
                Text(preset.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
            }
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.name)
        .accessibilityValue(preset.summary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("preset.\(preset.id)")
    }
}
