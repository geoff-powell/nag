import NagKit
import SwiftUI

struct TaskEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let isNew: Bool
    @State private var task: NagTask
    @State private var startNow: Bool
    @State private var limitSnoozes: Bool
    @State private var confirmDelete = false

    init(task: NagTask?) {
        isNew = task == nil
        let initial = task ?? NagTask(title: "")
        _task = State(initialValue: initial)
        _startNow = State(initialValue: task == nil)
        _limitSnoozes = State(initialValue: initial.style.maxSnoozes != nil)
    }

    static let intervals = [1, 2, 5, 10, 15, 30, 60]
    static let snoozeLengths = [5, 10, 15, 30, 60]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What needs doing?", text: $task.title)
                        .font(.headline)
                    TextField("Notes, or the first tiny step", text: $task.notes, axis: .vertical)
                        .lineLimit(1...4)
                }

                Section("When") {
                    Toggle("Start nagging now", isOn: $startNow)
                    if !startNow {
                        DatePicker("Starts", selection: $task.startAt)
                    }
                    Picker("Repeat", selection: $task.repeatRule) {
                        ForEach(RepeatRule.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }

                Section {
                    Picker("Nag every", selection: $task.style.intervalMinutes) {
                        ForEach(Self.intervals, id: \.self) { Text(NagFormat.minutes($0)).tag($0) }
                    }
                    Picker("Escalation", selection: $task.style.escalation) {
                        ForEach(Escalation.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle("Break through Focus", isOn: $task.style.breakThroughFocus)
                } header: {
                    Text("Nagging")
                } footer: {
                    Text(task.style.escalation.explanation)
                }

                Section {
                    Picker("Snooze for", selection: $task.style.snoozeMinutes) {
                        ForEach(Self.snoozeLengths, id: \.self) { Text(NagFormat.minutes($0)).tag($0) }
                    }
                    Toggle("Limit snoozes", isOn: $limitSnoozes)
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
                        .disabled(task.title.trimmingCharacters(in: .whitespaces).isEmpty)
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

    private func save() {
        if startNow && isNew { task.startAt = .now }
        if !limitSnoozes { task.style.maxSnoozes = nil }
        model.saveTask(task)
        dismiss()
    }
}
