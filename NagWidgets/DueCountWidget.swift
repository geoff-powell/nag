import NagCore
import SwiftUI
import WidgetKit

struct DueCountWidget: Widget {
    static let kind = "DueCount"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            DueCountView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Nag Count")
        .description("How many nags are due, and how late the oldest one is.")
        .supportedFamilies([.accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}

struct DueCountView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    if snapshot.dueCount == 0 {
                        Image(systemName: "checkmark").font(.title.bold()).accessibilityLabel("Nothing due")
                    } else {
                        VStack(spacing: 0) {
                            Image(systemName: "bell.fill")
                            Text("\(snapshot.dueCount)").font(.title2.bold())
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(snapshot.dueCount) nags due")
                    }
                }
            case .accessoryInline:
                inline
            default:
                rectangular
            }
        }
        .widgetURL(destination)
        .containerBackground(.clear, for: .widget)
    }

    @ViewBuilder private var inline: some View {
        if let oldest = snapshot.oldestOverdue {
            Text("\(snapshot.dueCount) nags · \(oldest.dueAt, style: .relative) late")
        } else {
            Text(snapshot.dueCount == 0 ? "Nothing due" : "\(snapshot.dueCount) nags due")
        }
    }

    @ViewBuilder private var rectangular: some View {
        if let oldest = snapshot.oldestOverdue {
            VStack(alignment: .leading, spacing: 1) {
                Label("\(snapshot.dueCount) nags due", systemImage: "bell.fill").font(.headline)
                Text(oldest.title).lineLimit(1)
                Text(oldest.dueAt, style: .relative).font(.caption)
            }
        } else {
            Label(snapshot.dueCount == 0 ? "Nothing due" : "\(snapshot.dueCount) nags due", systemImage: "checkmark.circle")
        }
    }

    private var destination: URL {
        snapshot.oldestOverdue.map { NagRoute.nag($0.id).url } ?? NagRoute.nags.url
    }
}
