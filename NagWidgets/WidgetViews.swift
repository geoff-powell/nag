import NagCore
import NagKit
import SwiftUI
import WidgetKit

struct NagRowView: View {
    let summary: NagSummary
    var actionsInline = false

    var body: some View {
        if actionsInline {
            HStack(spacing: Space.xs) {
                titleAndTime
                Spacer(minLength: Space.xxs)
                actions
            }
        } else {
            VStack(alignment: .leading, spacing: Space.xs) {
                titleAndTime
                actions
            }
        }
    }

    private var titleAndTime: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(spacing: Space.xs) {
                Text(summary.title).font(.headline).lineLimit(1)
                if summary.isSnoozed {
                    Image(systemName: "moon.zzz.fill").accessibilityLabel("Snoozed")
                } else if summary.isStarted {
                    Image(systemName: "hammer.fill").accessibilityLabel("Working")
                }
            }
            Text(summary.dueAt, style: .relative).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        HStack(spacing: Space.xs) {
            if summary.needsKeyScan {
                Link(destination: NagRoute.scan(taskID: summary.id).url) {
                    Label("Scan", systemImage: "barcode.viewfinder")
                        .frame(minWidth: Metrics.minTapTarget, minHeight: Metrics.minTapTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityHint("Opens Nag to scan the required key")
            } else if summary.canComplete {
                Button(intent: CompleteNagIntent(nag: NagEntity(summary: summary))) {
                    Label("Done", systemImage: "checkmark")
                        .frame(minWidth: Metrics.minTapTarget, minHeight: Metrics.minTapTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Mark \(summary.title) done")
            }
            if summary.canSnooze {
                Button(intent: SnoozeNagIntent(nag: NagEntity(summary: summary), length: nil)) {
                    Label("Snooze", systemImage: "clock")
                        .frame(minWidth: Metrics.minTapTarget, minHeight: Metrics.minTapTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Snooze \(summary.title)")
            }
        }
            .font(.caption.bold())
            .labelStyle(ActionLabelStyle(iconOnly: actionsInline))
            .buttonStyle(.plain)
    }
}

struct EmptyNagsView: View {
    var body: some View {
        Link(destination: NagRoute.nags.url) {
            VStack(spacing: Space.s) {
                Image(systemName: "checkmark.circle.fill").font(.title)
                Text("Nothing due").font(.headline)
                Text("You're all caught up").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct LockRowView: View {
    let summary: LockSummary
    var compact = false

    var body: some View {
        Link(destination: NagRoute.unlock(profileID: summary.id).url) {
            HStack(spacing: Space.s) {
                Image(systemName: summary.symbol)
                    .frame(width: Metrics.iconColumnCompact)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(summary.name).font(.headline).lineLimit(1)
                    status
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder private var status: some View {
        if let openUntil = summary.openUntil, openUntil > .now {
            HStack(spacing: Space.xs) {
                Text("Open")
                Text(openUntil, style: .timer)
            }
        } else if let waitEndsAt = summary.waitEndsAt, waitEndsAt > .now {
            HStack(spacing: Space.xs) {
                Text("Wait")
                Text(waitEndsAt, style: .timer)
            }
        } else if summary.isShielding {
            Text(lockStatus)
        } else {
            Text("Temporarily open")
        }
    }

    private var lockStatus: String {
        guard summary.stepsRemaining > 0 else { return "On" }
        if compact { return "On · \(summary.stepsRemaining) left" }
        return summary.stepsRemaining == 1 ? "On · 1 step left" : "On · \(summary.stepsRemaining) steps left"
    }
}

/// Icons only when the actions sit inline with the title, words otherwise.
private struct ActionLabelStyle: LabelStyle {
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            configuration.icon
        } else {
            configuration.title
        }
    }
}
