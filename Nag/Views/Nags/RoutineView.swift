import NagKit
import SwiftUI

/// A routine, one step at a time, with a big Next button.
struct RoutineView: View {
    let taskID: UUID

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var stepTick = 0
    @State private var finishTick = 0

    var body: some View {
        NavigationStack {
            Group {
                if let task = model.state.task(taskID), task.hasSteps {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        content(task, now: max(context.date, .now))
                    }
                } else {
                    ContentUnavailableView("This routine has no steps", systemImage: "list.number")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $scanning, onDismiss: {
                // The scan finished the nag: the routine is done too.
                if model.state.task(taskID)?.allStepsDone != true { dismiss() }
            }) {
                TaskProofSheet(taskID: taskID)
            }
            .sensoryFeedback(.increase, trigger: stepTick)
            .sensoryFeedback(.success, trigger: finishTick)
        }
    }

    @ViewBuilder
    private func content(_ task: NagTask, now: Date) -> some View {
        let done = task.completedStepIDs.count
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text(task.title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ProgressView(value: Double(done), total: Double(task.steps.count))
                    .tint(.orange)
                Text(task.stepLabel ?? "")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("routine.progress")
            }

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                if let step = task.currentStep {
                    Text(step.title)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                        .id(step.id)
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))
                        .accessibilityIdentifier("routine.step")
                    if let minutes = step.estimateMinutes {
                        Label("About \(NagFormat.minutes(minutes))", systemImage: "timer")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label("Every step is done", systemImage: "checkmark.circle.fill")
                        .font(.title.bold())
                        .foregroundStyle(.green)
                }
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)

            if let finish = task.estimatedFinish(at: now) {
                Text("Done by about \(finish.formatted(date: .omitted, time: .shortened))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("routine.finish")
            }

            Button {
                next(task)
            } label: {
                Text(buttonTitle(task))
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .tint(task.remainingSteps.count > 1 ? .orange : .green)
            .disabled(!task.canComplete(at: now, calendar: model.calendar))
            .accessibilityIdentifier("routine.next")
        }
        .padding(24)
        .animation(Motion.list, value: task.currentStep?.id)
    }

    private func buttonTitle(_ task: NagTask) -> String {
        if task.remainingSteps.count > 1 { return "Next" }
        return model.proofKey(for: task) != nil ? "Scan to finish" : "Finish"
    }

    private func next(_ task: NagTask) {
        let needsScan = model.proofKey(for: task) != nil
        if task.allStepsDone {
            if needsScan {
                scanning = true
            } else {
                model.complete(task.id)
                finishTick += 1
                dismiss()
            }
            return
        }
        switch model.completeStep(task.id) {
        case .nextStep:
            stepTick += 1
        case .completed:
            finishTick += 1
            dismiss()
        case .needsKeyScan:
            scanning = true
        case nil:
            break
        }
    }
}
