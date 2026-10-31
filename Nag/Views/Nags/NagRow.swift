import NagKit
import SwiftUI

struct NagRow: View {
    let task: NagTask
    let now: Date
    let needsScan: Bool
    let onComplete: () -> Void

    @Environment(AppModel.self) private var model
    /// The check was just tapped: show it filled while the completion lands.
    @State private var checking = false
    @State private var checkBounces = 0

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: tapCheck) {
                Image(systemName: checkSymbol)
                    .font(.title2)
                    .foregroundStyle(checkColor)
                    .contentTransition(.symbolEffect(.replace.magic(fallback: .replace.downUp.byLayer)))
                    .symbolEffect(.bounce.up, options: .speed(1.4), value: checkBounces)
            }
            .buttonStyle(.plain)
            .disabled(checking || !task.canComplete(at: now, calendar: model.calendar))
            .sensoryFeedback(.success, trigger: checkBounces)
            .accessibilityLabel(needsScan ? "Scan to finish" : "Mark done")
            .accessibilityIdentifier("complete.\(task.title)")
            .accessibilityValue(checkState)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.body.weight(task.isOutstanding(at: now) ? .semibold : .regular))
                    .strikethrough(task.isFinished)
                    .foregroundStyle(task.isFinished ? .secondary : .primary)
                if !task.notes.isEmpty {
                    Text(task.notes)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Label {
                    Text(statusText)
                        .contentTransition(.opacity)
                } icon: {
                    Image(systemName: statusSymbol)
                        .contentTransition(.symbolEffect(.replace))
                }
                .font(.caption)
                .foregroundStyle(statusColor)
                .accessibilityIdentifier("status.\(task.title)")
                if task.isRepeating || needsScan || task.source != nil {
                    tags
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("tags.\(task.title)")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    /// Fills the check in place first, then completes, so the row only moves once the tap has landed.
    private func tapCheck() {
        guard !needsScan else {
            onComplete()
            return
        }
        withAnimation(Motion.quick) { checking = true }
        checkBounces += 1
        Task { @MainActor in
            try? await Task.sleep(for: Motion.checkBeat)
            onComplete()
            checking = false
        }
    }

    private var isDone: Bool {
        checking || task.isFinished || task.isSatisfied(at: now, calendar: model.calendar)
    }

    private var checkState: String {
        if task.isFinished || task.isSatisfied(at: now, calendar: model.calendar) { return "done" }
        if task.isSnoozed(at: now) { return "snoozed" }
        return task.isOutstanding(at: now) ? "due" : "upcoming"
    }

    private var checkSymbol: String {
        if isDone { return "checkmark.circle.fill" }
        return needsScan ? "wave.3.right.circle" : "circle"
    }

    private var checkColor: Color {
        if isDone { return .green }
        return task.isOutstanding(at: now) ? .orange : .secondary
    }

    private var statusText: String {
        if task.isFinished, let done = task.completedAt {
            return "Done \(done.formatted(.relative(presentation: .named)))"
        }
        if task.isSnoozed(at: now), let until = task.snoozedUntil {
            return "Snoozed until \(until.formatted(date: .omitted, time: .shortened))"
        }
        if task.isStarted(at: now), let startedAt = task.startedAt {
            let checkingIn = task.isWorking(at: now) ? "" : " · checking in"
            return "Started \(NagFormat.duration(now.timeIntervalSince(startedAt))) ago\(checkingIn)"
        }
        if task.isOutstanding(at: now) {
            let overdue = now.timeIntervalSince(task.startAt)
            let snoozes = task.snoozesLeft.map { $0 == 0 ? " · no snoozes left" : " · \($0) snooze\($0 == 1 ? "" : "s") left" } ?? ""
            return (overdue < 60 ? "Due now" : "Overdue \(NagFormat.duration(overdue))") + snoozes
        }
        if !task.isFinished, task.isSatisfied(at: now, calendar: model.calendar) {
            return "Done today · next \(task.startAt.formatted(.relative(presentation: .named)))"
        }
        return "Starts \(task.startAt.formatted(.relative(presentation: .named)))"
    }

    private var tags: Text {
        var parts: [Text] = []
        if task.isRepeating { parts.append(Text("\(Image(systemName: "repeat")) \(task.repeatLabel)")) }
        if needsScan { parts.append(Text("\(Image(systemName: "wave.3.right")) Scan to finish")) }
        if let source = task.source { parts.append(Text("\(Image(systemName: "arrow.down.app")) \(source)")) }
        return parts.dropFirst().reduce(parts.first ?? Text("")) { Text("\($0)   \($1)") }
    }

    private var statusSymbol: String {
        if task.isSnoozed(at: now) { return "zzz" }
        if task.isStarted(at: now) { return "play.circle" }
        return task.isOutstanding(at: now) ? "bell.fill" : "clock"
    }

    private var statusColor: Color {
        if task.isSnoozed(at: now) { return .indigo }
        if task.isStarted(at: now) { return .blue }
        return task.isOutstanding(at: now) ? .orange : .secondary
    }
}
