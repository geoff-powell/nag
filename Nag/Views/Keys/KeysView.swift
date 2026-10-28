import NagKit
import SwiftUI

struct KeysView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false

    var body: some View {
        List {
            Section {
                ForEach(model.state.keys) { key in
                    HStack {
                        Image(systemName: key.kind == .nfc ? "wave.3.right" : "qrcode")
                            .foregroundStyle(.orange)
                            .frame(width: 28)
                        VStack(alignment: .leading) {
                            Text(key.name)
                            Text(key.kind == .nfc ? "NFC tag" : "Code")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .deleteDisabled(!model.canDeleteKey(key.id))
                }
                .onDelete { offsets in
                    for index in offsets { model.deleteKey(model.state.keys[index].id) }
                }
            } footer: {
                Text("Keys are physical things you scan to unlock or to finish a nag, like Brick. Put one somewhere inconvenient (by the front door, on the gym bag) or where the task happens. Keys used by an active lock can't be removed.")
            }
        }
        .navigationTitle("Unlock keys")
        .toolbar {
            Button("Add key", systemImage: "plus") { adding = true }
        }
        .sheet(isPresented: $adding) { AddKeyView() }
        .overlay {
            if model.state.keys.isEmpty {
                ContentUnavailableView {
                    Label("No keys", systemImage: "key.horizontal")
                } description: {
                    Text("Pair any NFC sticker, or a QR code or barcode, even one printed by Nag.")
                } actions: {
                    Button("Add key") { adding = true }.buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

struct AddKeyView: View {
    enum Method: String, CaseIterable, Identifiable {
        case nfc = "NFC tag"
        case scanCode = "Existing code"
        case newQR = "New QR code"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var method: Method = NFCKeyReader.isAvailable ? .nfc : .newQR
    @State private var name = ""
    @State private var fingerprint: String?
    @State private var newPayload = KeyFingerprint.newCodePayload()
    @State private var reader = NFCKeyReader()
    @State private var error: String?
    @State private var cameraAllowed: Bool?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. Front door tag", text: $name)
                    Picker("Type", selection: $method) {
                        ForEach(Method.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: method) { fingerprint = nil; error = nil }
                }

                switch method {
                case .nfc:
                    Section {
                        Button {
                            Task { await scanNFC() }
                        } label: {
                            Label(fingerprint == nil ? "Scan tag" : "Tag scanned", systemImage: fingerprint == nil ? "wave.3.right" : "checkmark.circle.fill")
                        }
                        .disabled(!NFCKeyReader.isAvailable)
                    } footer: {
                        Text(NFCKeyReader.isAvailable
                            ? "Any NFC sticker, card or fob. Nothing is written to it."
                            : "This device can't read NFC tags.")
                    }
                case .scanCode:
                    Section {
                        if fingerprint != nil {
                            Label("Code scanned", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if cameraAllowed == true {
                            CodeScannerView { payload in
                                fingerprint = KeyFingerprint.code(payload)
                            }
                            .frame(height: 240)
                            .listRowInsets(EdgeInsets())
                        } else if cameraAllowed == false {
                            Text("Allow camera access in Settings to scan codes.")
                        }
                    } footer: {
                        Text("A barcode on something you own works too, like a cereal box or shampoo bottle.")
                    }
                    .task { cameraAllowed = await CodeScannerView.requestAccess() }
                case .newQR:
                    Section {
                        if let image = QRCode.image(for: newPayload) {
                            Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 220)
                                .frame(maxWidth: .infinity)
                            ShareLink(
                                item: Image(uiImage: image),
                                preview: SharePreview("Nag key", image: Image(uiImage: image))
                            ) {
                                Label("Share or print", systemImage: "printer")
                            }
                        }
                    } footer: {
                        Text("Print it and stick it somewhere. Save a copy away from your phone, because a screenshot on this phone could be scanned from another screen.")
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || currentFingerprint == nil)
                }
            }
        }
    }

    private var currentFingerprint: String? {
        method == .newQR ? KeyFingerprint.code(newPayload) : fingerprint
    }

    private func scanNFC() async {
        do {
            fingerprint = try await reader.scan(prompt: "Hold your iPhone near the tag.")
            error = nil
        } catch let nfcError as NFCKeyError {
            error = nfcError.localizedDescription
        } catch {
            // Cancelled.
        }
    }

    private func save() {
        guard let currentFingerprint else { return }
        let kind: UnlockKey.Kind = method == .nfc ? .nfc : .code
        let key = UnlockKey(name: name.trimmingCharacters(in: .whitespaces), kind: kind, fingerprint: currentFingerprint)
        if let existing = model.addKey(key) {
            error = "That's already paired as “\(existing)”."
        } else {
            dismiss()
        }
    }
}
