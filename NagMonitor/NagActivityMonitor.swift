import DeviceActivity
import NagKit

/// iOS wakes this at DeviceActivity boundaries even when Nag isn't running: schedule windows starting and
/// ending, timed unlocks expiring, nags starting, quiet hours. Each callback re-syncs, and NagEngine
/// works out what changed (lock or unlock apps, switch nags to repeating, pause for quiet hours).
final class NagActivityMonitor: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        NagEngine.handleActivityCallback()
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        NagEngine.handleActivityCallback()
    }
}
