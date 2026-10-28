import NagKit
import SwiftUI

/// Scans one paired key: the NFC sheet for tags, the camera for codes.
/// `onScan` gets the fingerprint and returns whether it was accepted.
struct KeyScanner: View {
    let key: UnlockKey
    let onScan: (String) -> Bool

    @State private var reader = NFCKeyReader()
    @State private var feedback: String?
    @State private var cameraAllowed: Bool?

    var body: some View {
        VStack(spacing: 14) {
            switch key.kind {
            case .nfc:
                Button {
                    Task { await scanNFC() }
                } label: {
                    Label("Scan \(key.name)", systemImage: "wave.3.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!NFCKeyReader.isAvailable)
                if !NFCKeyReader.isAvailable {
                    Text("This device can't read NFC tags.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .code:
                if cameraAllowed == true {
                    CodeScannerView { payload in
                        accept(KeyFingerprint.code(payload))
                    }
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                } else if cameraAllowed == false {
                    Text("Nag needs camera access to scan codes. Turn it on in Settings.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    ProgressView()
                }
            }
            if let feedback {
                Text(feedback)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }
        }
        .task {
            if key.kind == .code {
                cameraAllowed = await CodeScannerView.requestAccess()
            }
        }
    }

    private func scanNFC() async {
        do {
            let fingerprint = try await reader.scan(prompt: "Hold your iPhone near \(key.name).")
            accept(fingerprint)
        } catch {
            // Cancelling the system sheet isn't worth an error message.
        }
    }

    private func accept(_ fingerprint: String) {
        if onScan(fingerprint) {
            feedback = nil
        } else {
            withAnimation { feedback = "That's not \(key.name)." }
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}
