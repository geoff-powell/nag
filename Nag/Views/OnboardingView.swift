import NagKit
import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var screenTimeError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "bell.badge.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.orange)
                        Text("Nag")
                            .font(.largeTitle.bold())
                        Text("Reminders that don't give up, and locks that keep distracting apps closed until the important stuff is done.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    FeatureRow(
                        symbol: "bell.and.waves.left.and.right.fill",
                        title: "Nags until it's done",
                        detail: "Keeps reminding you, more often the longer it waits. Snoozes are limited."
                    )
                    FeatureRow(
                        symbol: "lock.app.dashed",
                        title: "Locks apps, like Brick",
                        detail: "Block the apps you pick. Unlock by finishing nags, scanning a tag, walking, or waiting."
                    )
                    FeatureRow(
                        symbol: "key.horizontal.fill",
                        title: "Physical keys",
                        detail: "Pair any NFC sticker or QR code and put it where the task happens."
                    )

                    VStack(spacing: 12) {
                        PermissionButton(
                            title: "Allow notifications",
                            isGranted: model.notificationStatus == .authorized
                        ) {
                            await model.requestNotifications()
                        }
                        PermissionButton(
                            title: "Allow Screen Time access",
                            isGranted: model.screenTimeStatus == .approved
                        ) {
                            screenTimeError = await model.requestScreenTime()
                        }
                        if let screenTimeError {
                            Text(screenTimeError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        Text("Nag needs both: notifications to nag you, Screen Time to block apps and to wake up on schedule.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    model.finishOnboarding()
                } label: {
                    Text("Get started")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
                .background(.bar)
            }
        }
        .tint(.orange)
        .task { await model.refreshPermissions() }
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }
}

struct PermissionButton: View {
    let title: String
    let isGranted: Bool
    let request: () async -> Void

    var body: some View {
        Button {
            Task { await request() }
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: isGranted ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundStyle(isGranted ? .green : .secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(isGranted)
    }
}
