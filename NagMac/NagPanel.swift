import AppKit
import NagKit
import SwiftUI

/// The always-visible reminder in the top-right corner while nags are due. It can be collapsed to a
/// small pill but not closed, and it expands itself again after a few minutes.
@MainActor
final class NagPanelController {
    static let showPanelKey = "showNagPanel"
    static let reexpandAfter: TimeInterval = 5 * 60

    private let model: MacModel
    private let panel = FloatingPanel(nonactivating: true)
    private var collapsedAt: Date?

    init(model: MacModel) {
        self.model = model
        panel.collectionBehavior.insert(.stationary)
        panel.becomesKeyOnlyIfNeeded = true
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: showPanelKey) as? Bool ?? true
    }

    func refresh(now: Date) {
        let state = model.state
        let visible = state.tasks
            .filter { task in
                task.isNagging(at: now) || (task.canUndoCompletion(at: now)
                    && task.completionUndo.map { now.timeIntervalSince($0.completedAtMoment) < NagUndo.toastDuration } == true)
            }
            .sorted { $0.startAt < $1.startAt }
        let naggingCount = visible.filter { $0.isNagging(at: now) }.count

        guard Self.isEnabled, !visible.isEmpty, !state.settings.quietHours.contains(now, calendar: model.calendar) else {
            panel.orderOut(nil)
            collapsedAt = nil
            return
        }

        if let collapsedAt, now.timeIntervalSince(collapsedAt) >= Self.reexpandAfter {
            self.collapsedAt = nil
            NSSound.beep()
        }

        let view = NagPanelView(
            tasks: visible,
            naggingCount: naggingCount,
            now: now,
            collapsed: collapsedAt != nil,
            needsPhoneScan: model.needsPhoneScan,
            onDone: { [weak self] id in self?.model.complete(id) },
            onUndo: { [weak self] id in self?.model.undo(id) },
            onSnooze: { [weak self] id, minutes in self?.model.snooze(id, minutes: minutes) },
            onToggle: { [weak self] in self?.toggleCollapsed() },
            onOpen: { [weak self] in self?.model.show(.nags) }
        )
        panel.setContent(view, width: collapsedAt == nil ? 340 : 170)
        position()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func toggleCollapsed() {
        collapsedAt = collapsedAt == nil ? .now : nil
        refresh(now: .now)
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16))
    }
}

private struct NagPanelView: View {
    let tasks: [NagTask]
    let naggingCount: Int
    let now: Date
    let collapsed: Bool
    let needsPhoneScan: (NagTask) -> Bool
    let onDone: (UUID) -> Void
    let onUndo: (UUID) -> Void
    let onSnooze: (UUID, Int) -> Void
    let onToggle: () -> Void
    let onOpen: () -> Void

    var body: some View {
        Group {
            if collapsed {
                Button(action: onToggle) {
                    Label(pillTitle, systemImage: "bell.badge.fill")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(.orange, in: Capsule())
            } else {
                expanded
            }
        }
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(naggingCount > 0 ? "Still waiting on you" : "Marked done", systemImage: "bell.badge.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
                Button(action: onOpen) { Image(systemName: "arrow.up.forward.app") }
                    .help("Open Nag")
                Button(action: onToggle) { Image(systemName: "chevron.up") }
                    .help("Shrink for a few minutes")
            }
            .buttonStyle(.borderless)

            ForEach(tasks.prefix(5)) { task in
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    Text(subtitle(for: task))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        if task.canUndoCompletion(at: now) {
                            Button("Undo") { onUndo(task.id) }
                                .buttonStyle(.borderedProminent)
                        } else if needsPhoneScan(task) {
                            Label("Scan on iPhone to finish", systemImage: "iphone.radiowaves.left.and.right")
                                .font(.caption)
                        } else {
                            Button("Done") { onDone(task.id) }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                        }
                        if task.canSnooze(at: now) {
                            Menu("Snooze") {
                                ForEach(SnoozeOption.allCases, id: \.self) { option in
                                    Button(option.label) { onSnooze(task.id, option.minutes) }
                                }
                            }
                        }
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            }
            if tasks.count > 5 {
                Text("and \(tasks.count - 5) more").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.orange.opacity(0.6), lineWidth: 1.5))
    }

    private func subtitle(for task: NagTask) -> String {
        if task.canUndoCompletion(at: now) { return "Marked done" }
        let overdue = now.timeIntervalSince(task.startAt)
        let late = overdue < 60 ? "Due now" : "Overdue \(NagFormat.duration(overdue))"
        guard let left = task.snoozesLeft else { return late }
        return left == 0 ? "\(late) · no snoozes left" : "\(late) · \(left) snooze\(left == 1 ? "" : "s") left"
    }

    private var pillTitle: String {
        guard naggingCount > 0 else { return "Undo completion" }
        return naggingCount == 1 ? "1 nag due" : "\(naggingCount) nags due"
    }
}
