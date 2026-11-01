import NagCore
import SwiftUI
import WidgetKit

struct DueNagsWidget: Widget {
    static let kind = "DueNags"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            DueNagsView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Nags Due")
        .description("What's due now, with Done and Snooze.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct DueNagsView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    var body: some View {
        let visibleDue = snapshot.due.prefix(family == .systemMedium ? 2 : 1)
        Group {
            if snapshot.due.isEmpty {
                EmptyNagsView()
            } else if family == .systemSmall {
                if let summary = snapshot.oldestOverdue ?? snapshot.due.first {
                    NagRowView(summary: summary)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(visibleDue)) { summary in
                        NagRowView(summary: summary, actionsInline: true)
                        if summary.id != visibleDue.last?.id { Divider() }
                    }
                    let remaining = snapshot.dueCount - visibleDue.count
                    if remaining > 0 {
                        Text("+\(remaining) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .widgetURL(NagRoute.nags.url)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}
