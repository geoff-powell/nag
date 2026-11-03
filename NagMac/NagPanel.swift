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
                task.isNagging(at: now) || isMidRoutine(task, now: now) || (task.canUndoCompletion(at: now)
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
            onNextStep: { [weak self] id in self?.model.completeStep(id) },
            onUndo: { [weak self] id in self?.model.undo(id) },
            onStart: { [weak self] id in self?.model.start(id) },
            onSnooze: { [weak self] id, minutes in self?.model.snooze(id, minutes: minutes) },
            onToggle: { [weak self] in self?.toggleCollapsed() },
            onOpen: { [weak self] in self?.model.show(.nags) }
        )
        panel.setContent(view, width: collapsedAt == nil ? 340 : 170)
        position()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// A routine stays on screen between steps, while its quiet window runs, so the next step is
    /// always one click away.
    private func isMidRoutine(_ task: NagTask, now: Date) -> Bool {
        task.hasSteps && task.isOutstanding(at: now) && !task.isSnoozed(at: now) && !task.completedStepIDs.isEmpty
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
    let onNextStep: (UUID) -> Void
    let onUndo: (UUID) -> Void
    let onStart: (UUID) -> Void
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
                    if showsStep(task) {
                        stepCard(task)
                    }
                    HStack {
                        if task.canUndoCompletion(at: now) {
                            Button("Undo") { onUndo(task.id) }
                                .buttonStyle(.borderedProminent)
                        } else if showsStep(task) {
                            // The Next button above does the work; Done here would skip the remaining steps.
                            EmptyView()
                        } else if needsPhoneScan(task) {
                            Label("Scan on iPhone to finish", systemImage: "iphone.radiowaves.left.and.right")
                                .font(.caption)
                        } else {
                            Button("Done") { onDone(task.id) }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                        }
                        if task.isOutstanding(at: now), !task.isStarted(at: now) {
                            Button("Started") { onStart(task.id) }
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

    /// A routine shows its current step with a big Next button instead of Done.
    private func showsStep(_ task: NagTask) -> Bool {
        task.hasSteps && !task.canUndoCompletion(at: now) && !(task.allStepsDone && needsPhoneScan(task))
    }

    private func stepCard(_ task: NagTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(task.stepLabel ?? "")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.orange)
                Spacer()
                if let finish = task.estimatedFinish(at: now) {
                    Text("Done by \(finish.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: Double(task.completedStepIDs.count), total: Double(task.steps.count))
                .tint(.orange)
            if let step = task.currentStep {
                Text(step.title)
                    .font(.title3.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .id(step.id)
                    .transition(.push(from: .trailing))
                if let minutes = step.estimateMinutes {
                    Label("About \(NagFormat.minutes(minutes))", systemImage: "timer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                withAnimation(.snappy) { onNextStep(task.id) }
            } label: {
                Text(nextTitle(task))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(task.remainingSteps.count > 1 ? .orange : .green)
            .disabled(!task.canComplete(at: now, calendar: .current))
        }
    }

    private func nextTitle(_ task: NagTask) -> String {
        if task.remainingSteps.count > 1 { return "Next" }
        return needsPhoneScan(task) ? "Done, then scan on iPhone" : "Finish"
    }

    private func subtitle(for task: NagTask) -> String {
        if task.canUndoCompletion(at: now) { return "Marked done" }
        if task.allStepsDone, needsPhoneScan(task) { return "Every step done · scan on iPhone to finish" }
        if task.isStarted(at: now), let startedAt = task.startedAt {
            let checkingIn = task.isWorking(at: now) ? "" : " · checking in"
            return "Started \(NagFormat.duration(now.timeIntervalSince(startedAt))) ago\(checkingIn)"
        }
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
