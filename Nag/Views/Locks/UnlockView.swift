import NagKit
import SwiftUI

/// Works through a lock's requirements and unlocks it.
struct UnlockView: View {
    let profileID: UUID

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var steps: Int?
    @State private var scanning: ScanTarget?
    @State private var typing: TypingTarget?
    @State private var confirmEmergency = false
    @State private var unlockedMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let profile = model.profile(profileID) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        content(profile, now: context.date)
                    }
                } else {
                    ContentUnavailableView("This lock was deleted", systemImage: "lock.slash")
                }
            }
            .navigationTitle("Unlock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task(id: profileID) { await pollSteps() }
        .sheet(item: $scanning) { target in
            NavigationStack {
                VStack(spacing: 20) {
                    Text("Scan \(target.key.name) to count toward unlocking.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    KeyScanner(key: target.key) { fingerprint in
                        guard fingerprint == target.key.fingerprint else { return false }
                        model.recordProof(profileID: profileID, requirementID: target.requirementID)
                        scanning = nil
                        return true
                    }
                    Spacer()
                }
                .padding()
                .navigationTitle("Scan key")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { scanning = nil }
                    }
                }
            }
        }
        .sheet(item: $typing) { target in
            PhraseEntryView(phrase: target.phrase) {
                model.recordProof(profileID: profileID, requirementID: target.requirementID)
            }
        }
    }

    @ViewBuilder
    private func content(_ profile: LockProfile, now: Date) -> some View {
        let statuses = model.evaluate(profile, steps: steps, now: now)
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: profile.symbol).foregroundStyle(.orange)
                        Text(profile.name).font(.title2.bold())
                        Spacer()
                        StatusPill(profile: profile, now: now)
                    }
                    Text(profile.message).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            if let unlockedMessage {
                Section {
                    Label(unlockedMessage, systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            }

            switch profile.status {
            case .off:
                Section {
                    Text("This lock is off. Your apps are open.")
                }
            case .unlocked(_, let until):
                Section {
                    Text("Open until \(until.formatted(date: .omitted, time: .shortened)), then it locks again.")
                    Button("Lock again now") { model.relockNow(profileID) }
                }
            case .locked:
                Section("To unlock") {
                    if statuses.isEmpty {
                        Text("This lock has no requirements. Only an emergency unlock opens it.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(statuses) { status in
                        RequirementRow(status: status) {
                            action(for: status, profile: profile)
                        }
                    }
                }

                Section {
                    Button {
                        if model.unlock(profileID, steps: steps) {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            unlockedMessage = model.profile(profileID).map(NagEngine.unlockedMessage) ?? "Unlocked."
                        }
                    } label: {
                        Label("Unlock", systemImage: "lock.open.fill")
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(statuses.isEmpty || !statuses.allSatisfy(\.isMet))
                    .listRowInsets(EdgeInsets())
                }

                Section {
                    Button("Emergency unlock", role: .destructive) { confirmEmergency = true }
                        .disabled(model.emergencyUnlocksLeft == 0)
                } footer: {
                    Text("\(model.emergencyUnlocksLeft) of \(model.state.settings.emergencyUnlocksPerMonth) emergency unlocks left this month. They switch the lock off without meeting the requirements.")
                }
            }
        }
        .confirmationDialog(
            "Use an emergency unlock?",
            isPresented: $confirmEmergency,
            titleVisibility: .visible
        ) {
            Button("Unlock anyway", role: .destructive) {
                model.emergencyUnlock(profileID)
                dismiss()
            }
        } message: {
            Text("You have \(model.emergencyUnlocksLeft) left this month. Is this really an emergency, or is it the urge talking?")
        }
    }

    private func action(for status: RequirementStatus, profile: LockProfile) -> RequirementRow.Action? {
        guard !status.isMet else { return nil }
        switch status.requirement.kind {
        case .completeTasks, .clearDueNags:
            return .init(title: "Go to nags") {
                dismiss()
                router.tab = .nags
            }
        case .scanKey(let keyID):
            guard let key = model.state.key(keyID) else { return nil }
            return .init(title: "Scan") { scanning = ScanTarget(key: key, requirementID: status.requirement.id) }
        case .walk:
            return nil
        case .wait:
            guard profile.session?.unlockRequestedAt == nil else { return nil }
            return .init(title: "Start timer") { model.startWaitTimer(profileID) }
        case .typePhrase(let phrase):
            return .init(title: "Type it") { typing = TypingTarget(phrase: phrase, requirementID: status.requirement.id) }
        }
    }

    private func pollSteps() async {
        while !Task.isCancelled {
            if let profile = model.profile(profileID),
               let session = profile.session,
               profile.requirements.contains(where: { if case .walk = $0.kind { true } else { false } }) {
                steps = await StepCounter.steps(since: session.startedAt)
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }
}

private struct ScanTarget: Identifiable {
    let key: UnlockKey
    let requirementID: UUID
    var id: UUID { requirementID }
}

private struct TypingTarget: Identifiable {
    let phrase: String
    let requirementID: UUID
    var id: UUID { requirementID }
}

struct RequirementRow: View {
    struct Action {
        let title: String
        let perform: () -> Void
    }

    let status: RequirementStatus
    let action: () -> Action?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: status.isMet ? "checkmark.circle.fill" : status.requirement.kind.symbol)
                .font(.title3)
                .foregroundStyle(status.isMet ? .green : .orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(status.title)
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let progress = status.progress, !status.isMet {
                    ProgressView(value: progress)
                        .tint(.orange)
                }
            }
            Spacer()
            if let action = action() {
                Button(action.title, action: action.perform)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Type the commitment phrase by hand. Paste is refused so it can't be done on autopilot.
struct PhraseEntryView: View {
    let phrase: String
    let onMatch: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Type this exactly") {
                    Text(phrase)
                        .font(.body.italic())
                        .textSelection(.disabled)
                }
                Section {
                    TextField("Type here", text: $typed, axis: .vertical)
                        .lineLimit(2...6)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focused)
                        .onChange(of: typed) { old, new in
                            // A jump of more than a few characters at once is a paste.
                            if new.count - old.count > 3 { typed = old }
                        }
                } footer: {
                    if !typed.isEmpty && !UnlockEvaluator.phraseMatches(typed, phrase) {
                        Text("Keep going…")
                    }
                }
            }
            .navigationTitle("Commitment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onMatch()
                        dismiss()
                    }
                    .disabled(!UnlockEvaluator.phraseMatches(typed, phrase))
                }
            }
            .onAppear { focused = true }
        }
    }
}
