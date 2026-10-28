import AppKit
import NagKit
import SwiftUI

/// Covers a blocked app with what's holding it and what's left to do. The Mac counterpart of the
/// iPhone's shield screen.
@MainActor
final class ShieldPanelController {
    private let panel = FloatingPanel(nonactivating: false)

    func show(app: BlockedApp, profile: LockProfile, remaining: [String], onUnlock: @escaping () -> Void) {
        let view = ShieldView(app: app, profile: profile, remaining: remaining) { [weak self] in
            self?.close()
            onUnlock()
        } onDismiss: { [weak self] in
            self?.close()
        }
        panel.setContent(view, width: 520)
        panel.center()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel.orderOut(nil)
    }
}

private struct ShieldView: View {
    let app: BlockedApp
    let profile: LockProfile
    let remaining: [String]
    let onUnlock: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 84, height: 84)
                    .saturation(0)
                    .opacity(0.8)
                Image(systemName: "lock.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white, .orange)
                    .offset(x: 6, y: 6)
            }

            VStack(spacing: 6) {
                Text("\(app.name) is locked")
                    .font(.title.bold())
                Text("by \(profile.name)\(profile.strict ? " · strict" : "")")
                    .foregroundStyle(.secondary)
            }

            Text(profile.message)
                .font(.title3)
                .multilineTextAlignment(.center)

            if !remaining.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("To unlock").font(.headline)
                    ForEach(remaining, id: \.self) { item in
                        Label(item, systemImage: "circle")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }

            HStack {
                Button("OK", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Unlock…", action: onUnlock)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.orange.opacity(0.5), lineWidth: 1))
    }
}
