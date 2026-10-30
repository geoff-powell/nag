import SwiftUI

/// Shared animation timing, so every state change in the app moves the same way.
enum Motion {
    /// Rows moving between sections, appearing or disappearing. Quick and critically damped: settles
    /// without overshoot, so rows passing under section headers don't wobble.
    static let list = Animation.snappy(duration: 0.38)

    /// Small in-place changes: a status line, a toggle revealing a field, a check filling in.
    static let quick = Animation.snappy(duration: 0.22)

    /// How long a tapped check stays filled in place before its row moves to Done, so the tap
    /// registers before anything slides away.
    static let checkBeat: Duration = .milliseconds(380)

    /// How long a row's swipe actions take to close after one is tapped. A row that changes section
    /// before then arrives in its new section still swiped open, with its content off screen.
    static let swipeSettle: Duration = .milliseconds(300)
}
