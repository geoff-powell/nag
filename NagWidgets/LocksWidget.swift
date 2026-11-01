import NagCore
import SwiftUI
import WidgetKit

struct LocksWidget: Widget {
    static let kind = "Locks"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            LocksView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Locks")
        .description("Which locks are on, and what's left to open them.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}

struct LocksView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    var body: some View {
        Group {
            if snapshot.locks.isEmpty {
                Link(destination: NagRoute.nags.url) {
                    VStack(spacing: 6) {
                        Image(systemName: "lock.open.fill").font(.title)
                        Text("Nothing locked").font(.headline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if family == .accessoryRectangular {
                LockRowView(summary: snapshot.locks[0], compact: true)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(snapshot.locks.prefix(3))) { summary in
                        LockRowView(summary: summary)
                    }
                }
            }
        }
        .containerBackground(for: .widget) {
            if family == .accessoryRectangular {
                Color.clear
            } else {
                Color.clear.background(.fill.tertiary)
            }
        }
    }
}
