import NagKit
import SwiftUI

struct MenuBarView: View {
    @Environment(MacModel.self) private var model
    @State private var quickTitle = ""

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            // The tick's date can be up to 15s old when a change re-renders the menu.
            content(now: max(context.date, .now))
        }
        .frame(width: 340)
    }

    private func content(now: Date) -> some View {
        let groups = MacNagGroups(tasks: model.state.tasks, now: now, calendar: model.calendar)
        return VStack(alignment: .leading, spacing: 12) {
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
                    MenuNagRow(task: task, now: now)
                }
            }

            if !groups.later.isEmpty {
                Text("Coming up").font(.headline)
                ForEach(groups.later.prefix(3)) { task in
                    HStack {
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
                    HStack {
                        Image(systemName: profile.symbol)
                            .foregroundStyle(profile.isShielding(at: now) ? .orange : .secondary)
                            .frame(width: 18)
                        Text(profile.name).lineLimit(1)
                        Spacer()
                        MacStatusPill(profile: profile, now: now)
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
        .padding(14)
    }
}

private struct MenuNagRow: View {
    let task: NagTask
    let now: Date
    @Environment(MacModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).fontWeight(.medium).lineLimit(2)
                Text(task.isSnoozed(at: now)
                    ? "Snoozed until \(task.snoozedUntil?.formatted(date: .omitted, time: .shortened) ?? "")"
                    : "Overdue \(NagFormat.duration(now.timeIntervalSince(task.startAt)))")
                    .font(.caption)
                    .foregroundStyle(task.isSnoozed(at: now) ? Color.indigo : Color.orange)
            }
            Spacer()
            if model.needsPhoneScan(task) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .help("Scan on iPhone to finish")
            } else {
                Button("Done") { model.complete(task.id) }
            }
            if task.canSnooze(at: now) {
                Button {
                    model.snooze(task.id)
                } label: {
                    Image(systemName: "zzz")
                }
                .help("Snooze \(task.style.snoozeMinutes) minutes")
            }
        }
        .controlSize(.small)
    }
}

struct MacStatusPill: View {
    let profile: LockProfile
    let now: Date

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var text: String {
        switch profile.status {
        case .off: "Off"
        case .locked: "Locked"
        case .unlocked(_, let until):
            until > now ? "Open until \(until.formatted(date: .omitted, time: .shortened))" : "Locking…"
        }
    }

    private var color: Color {
        switch profile.status {
        case .off: .secondary
        case .locked: .orange
        case .unlocked: .green
        }
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
