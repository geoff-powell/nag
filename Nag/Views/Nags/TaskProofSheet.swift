import NagKit
import SwiftUI

/// Finishing a nag that needs its key scanned.
struct TaskProofSheet: View {
    let taskID: UUID

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if let task = model.state.task(taskID) {
                    content(task)
                } else {
                    ContentUnavailableView("This nag was deleted", systemImage: "trash")
                }
            }
            .navigationTitle("Scan to finish")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ task: NagTask) -> some View {
        if let key = model.proofKey(for: task) {
            VStack(spacing: 20) {
                Text(task.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("Scan \(key.name) to mark this done.")
                    .foregroundStyle(.secondary)
                KeyScanner(key: key) { fingerprint in
                    if model.complete(taskID, scannedFingerprint: fingerprint) {
                        model.celebrate(reduceMotion: reduceMotion)
                        dismiss()
                        return true
                    }
                    return false
                }
                if let message {
                    Text(message).foregroundStyle(.red)
                }
                Spacer()
            }
            .padding()
        } else {
            // The key was removed: fall back to a plain Done.
            VStack(spacing: 16) {
                Text(task.title).font(.title2.bold())
                Text("Its key was removed, so tapping Done is enough.")
                    .foregroundStyle(.secondary)
                Button("Done") {
                    model.complete(taskID)
                    model.celebrate(reduceMotion: reduceMotion)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }
}
