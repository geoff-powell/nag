@preconcurrency import CoreMotion
import Foundation

/// Steps walked since a lock started, for walk requirements.
enum StepCounter {
    static var isAvailable: Bool {
        CMPedometer.isStepCountingAvailable()
    }

    /// `nil` when step counting isn't available or Motion & Fitness access was denied.
    static func steps(since start: Date) async -> Int? {
        guard isAvailable else { return nil }
        // The pedometer keeps seven days of history.
        let from = max(start, .now.addingTimeInterval(-7 * 86_400))
        let pedometer = CMPedometer()
        return await withCheckedContinuation { continuation in
            pedometer.queryPedometerData(from: from, to: .now) { data, _ in
                // Keep the pedometer alive until it answers.
                _ = pedometer
                continuation.resume(returning: data.map { $0.numberOfSteps.intValue })
            }
        }
    }
}
