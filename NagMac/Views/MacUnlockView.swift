import NagKit
import SwiftUI

struct MacUnlockView: View {
    let profileID: UUID
    @Environment(MacModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var typed: [UUID: String] = [:]
    @State private var confirmEmergency = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            if let profile = model.profile(profileID) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    content(profile, now: context.date)
                }
            } else {
                ContentUnavailableView("This lock was deleted", systemImage: "lock.slash")
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 520, height: 560)
    }

    private func content(_ profile: LockProfile, now: Date) -> some View {
        let statuses = model.evaluate(profile, now: now)
        return Form {
            Section {
                HStack {
                    Image(systemName: profile.symbol).foregroundStyle(.orange)
                    Text(profile.name).font(.title2.bold())
                    Spacer()
                    MacStatusPill(profile: profile, now: now)
                }
                Text(profile.message).foregroundStyle(.secondary)
                if let message {
                    Label(message, systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
            }

            switch profile.status {
            case .off:
                Text("This lock is off. Your apps are open.")
            case .unlocked(_, let until):
                Section {
                    Text("Open until \(until.formatted(date: .omitted, time: .shortened)), then it locks again.")
                    Button("Lock again now") { model.relockNow(profileID) }
                }
            case .locked:
                Section("To unlock") {
                    ForEach(statuses) { status in
                        requirementRow(status, profile: profile)
                    }
                }
                Section {
                    Button("Unlock") {
                        if model.unlock(profileID) {
                            message = model.profile(profileID).map(MacModel.unlockedMessage) ?? "Unlocked."
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(statuses.isEmpty || !statuses.allSatisfy(\.isMet))
                }
                Section {
                    Button("Emergency unlock…", role: .destructive) { confirmEmergency = true }
                        .disabled(model.emergencyUnlocksLeft == 0)
                } footer: {
                    Text("\(model.emergencyUnlocksLeft) of \(model.state.settings.emergencyUnlocksPerMonth) left this month.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Use an emergency unlock?", isPresented: $confirmEmergency) {
            Button("Unlock anyway", role: .destructive) {
                model.emergencyUnlock(profileID)
                dismiss()
            }
        } message: {
            Text("You have \(model.emergencyUnlocksLeft) left this month. Is this an emergency, or the urge talking?")
        }
    }

    @ViewBuilder
    private func requirementRow(_ status: RequirementStatus, profile: LockProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: status.isMet ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(status.isMet ? .green : .orange)
                Text(status.title)
                Spacer()
                Text(status.detail).font(.caption).foregroundStyle(.secondary)
            }
            if let progress = status.progress, !status.isMet {
                ProgressView(value: progress).tint(.orange)
            }
            if !status.isMet {
                actions(for: status, profile: profile)
            }
        }
    }

    @ViewBuilder
    private func actions(for status: RequirementStatus, profile: LockProfile) -> some View {
        switch status.requirement.kind {
        case .completeTasks(let ids):
            ForEach(ids.compactMap(model.state.task).filter { !$0.isSatisfied(at: .now, calendar: model.calendar) }) { task in
                nagLine(task)
            }
        case .clearDueNags:
            ForEach(model.state.tasks.filter { $0.isOutstanding(at: .now) }) { task in
                nagLine(task)
            }
        case .wait:
            if profile.session?.unlockRequestedAt == nil {
                Button("Start timer") { model.startWaitTimer(profileID) }
            }
        case .typePhrase(let phrase):
            Text(phrase).italic()
            TextField("Type it here", text: Binding(
                get: { typed[status.id] ?? "" },
                set: { new in
                    let old = typed[status.id] ?? ""
                    // A jump of several characters at once is a paste.
                    guard new.count - old.count <= 3 else { return }
                    typed[status.id] = new
                    if UnlockEvaluator.phraseMatches(new, phrase) {
                        model.recordProof(profileID: profileID, requirementID: status.id)
                    }
                }
            ))
            .autocorrectionDisabled()
        case .walk, .scanKey:
            Label("Do this on your iPhone.", systemImage: "iphone")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func nagLine(_ task: NagTask) -> some View {
        HStack {
            Text(task.title).font(.callout)
            Spacer()
            if model.needsPhoneScan(task) {
                Text("Scan on iPhone").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Done") { model.complete(task.id) }.controlSize(.small)
            }
        }
        .padding(.leading, 24)
    }
}
