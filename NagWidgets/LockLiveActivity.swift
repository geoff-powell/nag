import ActivityKit
import NagKit
import SwiftUI
import WidgetKit

struct LockLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LockActivityAttributes.self) { context in
            LockActivityLockScreenView(context: context)
                .activityBackgroundTint(.black.opacity(0.4))
                .activitySystemActionForegroundColor(.orange)
                .widgetURL(NagRoute.unlock(profileID: context.attributes.profileID).url)
        } dynamicIsland: { context in
            let content = context.state.content
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: content.symbol)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.isStale {
                        Image(systemName: "arrow.clockwise")
                    } else {
                        LockActivityCompactStatus(content: content)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(content.name).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.isStale {
                        Text("Open Nag to refresh")
                    } else {
                        LockActivityStatus(content: content)
                    }
                }
            } compactLeading: {
                Image(systemName: content.symbol)
            } compactTrailing: {
                if context.isStale {
                    Image(systemName: "arrow.clockwise")
                } else {
                    LockActivityCompactStatus(content: content)
                }
            } minimal: {
                Image(systemName: content.symbol)
            }
            .widgetURL(NagRoute.unlock(profileID: content.profileID).url)
            .keylineTint(.orange)
        }
    }
}
