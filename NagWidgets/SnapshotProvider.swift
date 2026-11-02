import NagCore
import WidgetKit

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .sample())
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let now = Date.now
        let snapshot = context.isPreview
            ? WidgetSnapshot.sample(now: now)
            : WidgetSnapshot.make(from: SharedStore.shared.load(), now: now, calendar: .current)
        completion(SnapshotEntry(date: now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date.now
        let state = SharedStore.shared.load()
        let calendar = Calendar.current
        let snapshot = WidgetSnapshot.make(from: state, now: now, calendar: calendar)
        let fallback = now.addingTimeInterval(45 * 60)
        let minimumRefresh = now.addingTimeInterval(5 * 60)
        var entries = [SnapshotEntry(date: now, snapshot: snapshot)]
        var boundary = max(snapshot.nextChange ?? fallback, minimumRefresh)

        if snapshot.nextChange != nil {
            for _ in 0..<8 {
                let futureSnapshot = WidgetSnapshot.make(from: state, now: boundary, calendar: calendar)
                entries.append(SnapshotEntry(date: boundary, snapshot: futureSnapshot))
                guard let nextBoundary = futureSnapshot.nextChange else { break }
                boundary = max(nextBoundary, boundary.addingTimeInterval(1))
            }
        }

        let refresh = entries.count > 1 ? entries[entries.count - 1].date : boundary
        completion(Timeline(entries: entries, policy: .after(refresh)))
    }
}
