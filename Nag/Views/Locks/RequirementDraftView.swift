import NagKit
import SwiftUI

enum RequirementDraft {
    enum Kind: String, CaseIterable, Identifiable {
        case completeTasks
        case clearDueNags
        case scanKey
        case walk
        case wait
        case typePhrase

        var id: String { rawValue }

        var label: String {
            switch self {
            case .completeTasks: "Finish specific nags"
            case .clearDueNags: "Clear every due nag"
            case .scanKey: "Scan a key"
            case .walk: "Go for a walk"
            case .wait: "Wait it out"
            case .typePhrase: "Type a commitment"
            }
        }

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
}

/// Collects the details for a new unlock requirement.
struct RequirementDraftView: View {
    let kind: RequirementDraft.Kind
    let onAdd: (UnlockRequirement) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var taskIDs: Set<UUID> = []
    @State private var keyID: UUID?
    @State private var steps = 1000
    @State private var minutes = 10
    @State private var phrase = "I'm choosing distraction over what I said I'd do."

    var body: some View {
        NavigationStack {
            Form {
                switch kind {
                case .completeTasks:
                    Section {
                        ForEach(model.state.tasks.filter { !$0.isFinished }) { task in
                            Button {
                                if taskIDs.contains(task.id) { taskIDs.remove(task.id) } else { taskIDs.insert(task.id) }
                            } label: {
                                HStack {
                                    Text(task.title).foregroundStyle(.primary)
                                    Spacer()
                                    if taskIDs.contains(task.id) {
                                        Image(systemName: "checkmark").foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                    } footer: {
                        Text("For repeating nags, today's one has to be done.")
                    }
                case .clearDueNags:
                    EmptyView()
                case .scanKey:
                    Picker("Key", selection: $keyID) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(model.state.keys) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    .pickerStyle(.inline)
                case .walk:
                    Section {
                        Stepper("\(steps.formatted()) steps", value: $steps, in: 100...20_000, step: 250)
                    } footer: {
                        Text(StepCounter.isAvailable
                            ? "Counted from when the lock started."
                            : "This device can't count steps, so this requirement can't be met here.")
                    }
                case .wait:
                    Section {
                        Stepper(NagFormat.minutes(minutes), value: $minutes, in: 1...120)
                    } footer: {
                        Text("You start the timer when you want in. Long enough for the urge to pass.")
                    }
                case .typePhrase:
                    Section {
                        TextField("Phrase", text: $phrase, axis: .vertical)
                            .lineLimit(2...5)
                    } footer: {
                        Text("Typed out by hand each time. Pasting is blocked.")
                    }
                }
            }
            .navigationTitle(kind.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let requirement { onAdd(requirement) }
                        dismiss()
                    }
                    .disabled(requirement == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var requirement: UnlockRequirement? {
        let kind: UnlockRequirement.Kind? = switch self.kind {
        case .completeTasks: taskIDs.isEmpty ? nil : .completeTasks(model.state.tasks.map(\.id).filter(taskIDs.contains))
        case .clearDueNags: .clearDueNags
        case .scanKey: keyID.map(UnlockRequirement.Kind.scanKey)
        case .walk: .walk(steps: steps)
        case .wait: .wait(minutes: minutes)
        case .typePhrase:
            phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .typePhrase(phrase.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return kind.map { UnlockRequirement(kind: $0) }
    }
}
