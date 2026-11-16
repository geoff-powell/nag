import ActivityKit
import NagKit
import SwiftUI
import WidgetKit

struct NagActivityLockScreenView: View {
    let context: ActivityViewContext<NagActivityAttributes>

    var body: some View {
        let content = context.state.content
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Label(content.title, systemImage: "bell.badge.fill")
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: Space.s)
                if !context.isStale {
                    Text(content.dueAt, style: .relative)
                        .font(.subheadline.monospacedDigit())
                }
            }
            if context.isStale {
                Text("Open Nag to refresh")
                    .foregroundStyle(.secondary)
            } else {
                Text(content.headline)
                    .font(.subheadline)
            }
            if content.needsKeyScan || content.canComplete || content.canSnooze {
                NagActivityActions(content: content)
            }
        }
        .padding()
    }
}

struct NagActivityActions: View {
    let content: NagActivityContent

    var body: some View {
        HStack(spacing: Space.m) {
            if content.needsKeyScan {
                Button(intent: ScanProofIntent(nag: NagEntity(activityContent: content))) {
                    Label("Scan", systemImage: "barcode.viewfinder")
                        .frame(minWidth: Metrics.minTapTarget, minHeight: Metrics.minTapTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Scan key for \(content.title)")
                .accessibilityHint("Opens Nag to scan the required key")
            } else if content.canComplete {
                Button(intent: CompleteNagFromActivityIntent(nag: NagEntity(activityContent: content))) {
                    Label("Done", systemImage: "checkmark")
                        .frame(minWidth: Metrics.minTapTarget, minHeight: Metrics.minTapTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Mark \(content.title) done")
            }
            if content.canSnooze {
                Button(intent: SnoozeNagFromActivityIntent(nag: NagEntity(activityContent: content), length: nil)) {
                    Label("Snooze", systemImage: "clock")
                        .frame(minWidth: Metrics.minTapTarget, minHeight: Metrics.minTapTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Snooze \(content.title)")
            }
        }
        .font(.caption.bold())
        .buttonStyle(.bordered)
    }
}

struct LockActivityLockScreenView: View {
    let context: ActivityViewContext<LockActivityAttributes>

    var body: some View {
        let content = context.state.content
        VStack(alignment: .leading, spacing: Space.s) {
            Label(content.name, systemImage: content.symbol)
                .font(.headline)
            if context.isStale {
                Text("Open Nag to refresh")
                    .foregroundStyle(.secondary)
            } else {
                LockActivityStatus(content: content)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .contentShape(Rectangle())
    }
}

struct LockActivityStatus: View {
    let content: LockActivityContent

    var body: some View {
        if let openUntil = content.openUntil {
            HStack(spacing: Space.xs) {
                Text("Open until")
                Text(openUntil, style: .timer).monospacedDigit()
            }
        } else if let waitEndsAt = content.waitEndsAt {
            HStack(spacing: Space.xs) {
                Text("Wait")
                Text(waitEndsAt, style: .timer).monospacedDigit()
            }
        } else if content.remaining.isEmpty {
            Text("Lock is on")
        } else {
            VStack(alignment: .leading, spacing: Space.xxs) {
                ForEach(content.remaining, id: \.self) { Text($0) }
            }
        }
    }
}

struct LockActivityCompactStatus: View {
    let content: LockActivityContent

    var body: some View {
        if let openUntil = content.openUntil {
            Text(openUntil, style: .timer).monospacedDigit()
        } else if let waitEndsAt = content.waitEndsAt {
            Text(waitEndsAt, style: .timer).monospacedDigit()
        } else {
            Text("\(content.remaining.count)")
        }
    }
}
