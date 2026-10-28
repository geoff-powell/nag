import NagKit
import SwiftUI

struct NagRow: View {
    let task: NagTask
    let now: Date
    let needsScan: Bool
    let onComplete: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onComplete) {
                Image(systemName: checkSymbol)
                    .font(.title2)
                    .foregroundStyle(checkColor)
            }
            .buttonStyle(.plain)
            .disabled(!task.canComplete(at: now, calendar: model.calendar))
            .accessibilityLabel(needsScan ? "Scan to finish" : "Mark done")

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
                Label(statusText, systemImage: statusSymbol)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                if task.isRepeating || needsScan {
                    tags
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var checkSymbol: String {
        if task.isFinished || task.isSatisfied(at: now, calendar: model.calendar) { return "checkmark.circle.fill" }
        return needsScan ? "wave.3.right.circle" : "circle"
    }

    private var checkColor: Color {
        if task.isFinished || task.isSatisfied(at: now, calendar: model.calendar) { return .green }
        return task.isOutstanding(at: now) ? .orange : .secondary
    }

    private var statusText: String {
        if task.isFinished, let done = task.completedAt {
            return "Done \(done.formatted(.relative(presentation: .named)))"
        }
        if task.isSnoozed(at: now), let until = task.snoozedUntil {
            return "Snoozed until \(until.formatted(date: .omitted, time: .shortened))"
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
        if task.isRepeating { parts.append(Text("\(Image(systemName: "repeat")) \(task.repeatRule.label)")) }
        if needsScan { parts.append(Text("\(Image(systemName: "wave.3.right")) Scan to finish")) }
        return parts.dropFirst().reduce(parts.first ?? Text("")) { Text("\($0)   \($1)") }
    }

    private var statusSymbol: String {
        if task.isSnoozed(at: now) { return "zzz" }
        return task.isOutstanding(at: now) ? "bell.fill" : "clock"
    }

    private var statusColor: Color {
        if task.isSnoozed(at: now) { return .indigo }
        return task.isOutstanding(at: now) ? .orange : .secondary
    }
}
