import ActivityKit
import NagKit
import SwiftUI
import WidgetKit

struct NagLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NagActivityAttributes.self) { context in
            NagActivityLockScreenView(context: context)
                .activityBackgroundTint(.black.opacity(0.4))
                .activitySystemActionForegroundColor(.orange)
                .widgetURL(NagRoute.nag(context.attributes.taskID).url)
        } dynamicIsland: { context in
            let content = context.state.content
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(content.title, systemImage: "bell.badge.fill")
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !context.isStale {
                        Text(content.dueAt, style: .relative)
                            .monospacedDigit()
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.isStale ? "Open Nag to refresh" : content.headline)
                        .font(.caption)
                        .lineLimit(2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if content.needsKeyScan || content.canComplete || content.canSnooze {
                        NagActivityActions(content: content)
                    }
                }
            } compactLeading: {
                Image(systemName: "bell.badge.fill")
            } compactTrailing: {
                if context.isStale {
                    Image(systemName: "arrow.clockwise")
                } else {
                    Text(content.dueAt, style: .relative)
                        .monospacedDigit()
                }
            } minimal: {
                Image(systemName: context.isStale ? "arrow.clockwise" : "bell.badge.fill")
            }
            .widgetURL(NagRoute.nag(context.attributes.taskID).url)
            .keylineTint(.orange)
        }
    }
}
