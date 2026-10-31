import NagKit
import SwiftUI

struct TaskEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let isNew: Bool
    private let original: NagTask?
    @State private var task: NagTask
    @State private var startNow: Bool
    @State private var limitSnoozes: Bool
    @State private var confirmDelete = false

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
        _limitSnoozes = State(initialValue: task.style.maxSnoozes != nil)
    }

    static let intervals = [1, 2, 5, 10, 15, 30, 60]
    static let snoozeLengths = [5, 10, 15, 30, 60]
    static let workLengths = [10, 15, 25, 30, 45, 60, 90]

    private var isCustom: Bool { task.repeatRule == .custom }

    var body: some View {
        NavigationStack {
            Form {
                Section("Start from") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(NagPreset.all) { preset in
                                VStack(alignment: .leading, spacing: 6) {
                                    Button {
                                        withAnimation(Motion.list) {
                                            preset.apply(to: &task, keys: model.state.keys, now: .now, calendar: .current)
                                            limitSnoozes = task.style.maxSnoozes != nil
                                        }
                                    } label: {
                                        Label(preset.name, systemImage: preset.symbol)
                                    }
                                    .buttonStyle(.bordered)
                                    Text(preset.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: 150, alignment: .leading)
                                }
                            }
                        }
                    }
                }

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
                        ForEach(Self.intervals, id: \.self) { Text(NagFormat.minutes($0)).tag($0) }
                    }
                    Picker("Escalation", selection: $task.style.escalation) {
                        ForEach(Escalation.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Tone", selection: $task.style.tone) {
                        Text("Use the default").tag(NagTone?.none)
                        ForEach(NagTone.allCases, id: \.self) { Text($0.label).tag(NagTone?.some($0)) }
                    }
                    Picker("Working time", selection: $task.style.workMinutes) {
                        ForEach(Self.workLengths, id: \.self) { Text(NagFormat.minutes($0)).tag($0) }
                    }
                    Toggle("Break through Focus", isOn: $task.style.breakThroughFocus)
                } header: {
                    Text("Nagging")
                } footer: {
                    Text("After you tap Started, Nag goes quiet for this long, then checks in.")
                }

                Section {
                    Picker("Snooze for", selection: $task.style.snoozeMinutes) {
                        ForEach(Self.snoozeLengths, id: \.self) { Text(NagFormat.minutes($0)).tag($0) }
                    }
                    Toggle("Limit snoozes", isOn: $limitSnoozes.animation(Motion.quick))
                    if limitSnoozes {
                        Stepper(
                            "\(task.style.maxSnoozes ?? 3) per occurrence",
                            value: Binding(get: { task.style.maxSnoozes ?? 3 }, set: { task.style.maxSnoozes = $0 }),
                            in: 0...10
                        )
                    }
                } header: {
                    Text("Snooze")
                } footer: {
                    Text("Snoozed nags still count as due for locks.")
                }

                Section {
                    Picker("To finish", selection: proofBinding) {
                        Text("Tap Done").tag(UUID?.none)
                        ForEach(model.state.keys) { key in
                            Text("Scan \(key.name)").tag(UUID?.some(key.id))
                        }
                    }
                } header: {
                    Text("Proof")
                } footer: {
                    Text(model.state.keys.isEmpty
                        ? "Pair an NFC tag or QR code in Settings > Unlock keys to require a scan, e.g. a sticker on the pill bottle."
                        : "Requiring a scan means you have to go to where the task is to finish it.")
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
        if !limitSnoozes { task.style.maxSnoozes = nil }
        model.saveTask(task)
        dismiss()
    }
}
