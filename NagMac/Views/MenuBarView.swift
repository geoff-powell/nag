import NagKit
import SwiftUI

struct MenuBarView: View {
    @Environment(MacModel.self) private var model
    @State private var quickTitle = ""
    @State private var undo: (taskID: UUID, deadline: Date)?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            // The tick's date can be up to 15s old when a change re-renders the menu.
            content(now: max(context.date, .now))
        }
        .frame(width: 340)
    }

    private func content(now: Date) -> some View {
        let groups = MacNagGroups(tasks: model.state.tasks, now: now, calendar: model.calendar)
        return VStack(alignment: .leading, spacing: Space.m) {
            TextField("Add a nag and press Return", text: $quickTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    model.quickAdd(quickTitle)
                    quickTitle = ""
                }

            if groups.now.isEmpty {
                Label("Nothing due. Nice.", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
            } else {
                Text("Due now").font(.headline)
                ForEach(groups.now) { task in
                    MenuNagRow(task: task, now: now) { showUndo(for: task.id) }
                }
            }

            if let undo {
                HStack(spacing: Space.s) {
                    Text("Marked done")
                    Spacer()
                    Button("Undo") {
                        model.undo(undo.taskID)
                        self.undo = nil
                    }
                    Button("Dismiss", systemImage: "xmark") { self.undo = nil }
                        .labelStyle(.iconOnly)
                }
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.s)
                .background(.regularMaterial, in: Capsule())
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if !groups.later.isEmpty {
                Text("Coming up").font(.headline)
                ForEach(groups.later.prefix(3)) { task in
                    HStack(spacing: Space.s) {
                        Text(task.title).lineLimit(1)
                        Spacer()
                        Text(task.startAt, format: .relative(presentation: .named))
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }

            if !model.state.profiles.isEmpty {
                Divider()
                Text("Locks").font(.headline)
                ForEach(model.state.profiles) { profile in
                    HStack(spacing: Space.s) {
                        Image(systemName: profile.symbol)
                            .foregroundStyle(profile.isShielding(at: now) ? .orange : .secondary)
                            .frame(width: Metrics.iconColumnCompact)
                        Text(profile.name).lineLimit(1)
                        Spacer()
                        StatusPill(profile: profile, now: now)
                        switch profile.status {
                        case .off:
                            Button("Lock") { model.lockNow(profile.id) }
                                .disabled(profile.blockedApps.isEmpty)
                        case .locked:
                            Button("Unlock…") { model.showUnlock(profile.id) }
                        case .unlocked:
                            Button("Relock") { model.relockNow(profile.id) }
                        }
                    }
                    .controlSize(.small)
                }
            }

            Divider()
            HStack {
                Button("Open Nag") { model.show(.nags) }
                Spacer()
                Button("Settings…") { model.show(.settings) }
                Button("Quit") { NSApp.terminate(nil) }
                    .disabled(model.strictEngagedLock != nil)
                    .help(model.strictEngagedLock.map { "“\($0.name)” is in strict mode" } ?? "Quit Nag")
            }
        }
        .padding(Space.m)
        .animation(.snappy(duration: 0.38), value: undo?.deadline)
    }

    private func showUndo(for taskID: UUID) {
        let deadline = Date.now.addingTimeInterval(NagUndo.toastDuration)
        undo = (taskID, deadline)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(NagUndo.toastDuration))
            guard undo?.deadline == deadline else { return }
            undo = nil
        }
    }
}

private struct MenuNagRow: View {
    let task: NagTask
    let now: Date
    let onComplete: () -> Void
    @Environment(MacModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(task.title).fontWeight(.medium).lineLimit(2)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(task.isSnoozed(at: now) ? Color.indigo : task.isStarted(at: now) ? Color.blue : Color.orange)
            }
            Spacer()
            if model.needsPhoneScan(task) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .help("Scan on iPhone to finish")
            } else {
                Button("Done") {
                    model.complete(task.id)
                    onComplete()
                }
            }
            if task.canSnooze(at: now) {
                Menu {
                    ForEach(SnoozeOption.allCases, id: \.self) { option in
                        Button(option.label) { model.snooze(task.id, minutes: option.minutes) }
                    }
                } label: {
                    Label("Snooze", systemImage: "zzz")
                        .labelStyle(.iconOnly)
                }
                .help("Choose a snooze length")
            }
            if !task.isStarted(at: now) {
                Button("Started") { model.start(task.id) }
            }
        }
        .controlSize(.small)
    }

    private var status: String {
        if task.isSnoozed(at: now) {
            return "Snoozed until \(task.snoozedUntil?.formatted(date: .omitted, time: .shortened) ?? "")"
        }
        if task.isStarted(at: now), let startedAt = task.startedAt {
            let checkingIn = task.isWorking(at: now) ? "" : " · checking in"
            return "Started \(NagFormat.duration(now.timeIntervalSince(startedAt))) ago\(checkingIn)"
        }
        return "Overdue \(NagFormat.duration(now.timeIntervalSince(task.startAt)))"
    }
}

/// Splits nags into due now, coming up, and done today.
struct MacNagGroups {
    var now: [NagTask] = []
    var later: [NagTask] = []
    var done: [NagTask] = []

    init(tasks: [NagTask], now date: Date, calendar: Calendar) {
        for task in tasks {
            if task.isOutstanding(at: date) {
                now.append(task)
            } else if task.isFinished || task.lastCompletedAt.map({ calendar.isDate($0, inSameDayAs: date) }) == true {
                done.append(task)
            } else {
                later.append(task)
            }
        }
        now.sort { $0.startAt < $1.startAt }
        later.sort { $0.startAt < $1.startAt }
        done.sort { ($0.lastCompletedAt ?? .distantPast) > ($1.lastCompletedAt ?? .distantPast) }
    }
}
