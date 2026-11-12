import NagCore
import SwiftUI

/// The spacing scale shared by the iPhone app, the Mac app and the widgets. Every padding and stack
/// gap uses one of these steps, so equivalent views line up across platforms.
public enum Space {
    /// Title to subtitle inside one text group.
    public static let xxs: CGFloat = 2
    /// Tight pairs: pill vertical padding, row vertical padding, icon beside a caption.
    public static let xs: CGFloat = 4
    /// Related items: groups inside a row, controls in a button row, inset card gap.
    public static let s: CGFloat = 8
    /// Lead icon to text, card padding, compact container padding.
    public static let m: CGFloat = 12
    /// Container padding, toast horizontal padding, screen-edge inset.
    public static let l: CGFloat = 16
    /// Sections of a sheet or screen, padding of large panels.
    public static let xl: CGFloat = 24
    /// Top-level blocks of a full-screen layout.
    public static let xxl: CGFloat = 32
}

/// Corner radii. An inset surface inside a rounded container uses `outer - inset`, so
/// `panel` (22) with `Space.m` padding (12) holds `card` (10) concentrically.
public enum Radius {
    /// Inset cards inside a panel.
    public static let card: CGFloat = 10
    /// Media such as a camera preview.
    public static let media: CGFloat = 16
    /// Floating panels.
    public static let panel: CGFloat = 22
}

/// Fixed sizes that several views share.
public enum Metrics {
    /// Width of the leading symbol column in list rows, so titles line up down a list.
    public static let iconColumn: CGFloat = 32
    /// The same column in compact layouts: the menu bar and widgets.
    public static let iconColumnCompact: CGFloat = 20
    /// Height of a live camera preview for scanning codes.
    public static let cameraPreviewHeight: CGFloat = 260
    /// Smallest comfortable tap target.
    public static let minTapTarget: CGFloat = 44
}

/// The small capsule that shows whether a lock is off, locked or open.
public struct StatusPill: View {
    let profile: LockProfile
    let now: Date

    public init(profile: LockProfile, now: Date) {
        self.profile = profile
        self.now = now
    }

    public var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var text: String {
        switch profile.status {
        case .off: "Off"
        case .locked: "Locked"
        case .unlocked(_, let until):
            until > now ? "Open until \(until.formatted(date: .omitted, time: .shortened))" : "Locking…"
        }
    }

    private var color: Color {
        switch profile.status {
        case .off: .secondary
        case .locked: .orange
        case .unlocked: .green
        }
    }
}
