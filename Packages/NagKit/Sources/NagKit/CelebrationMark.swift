import NagCore
import SwiftUI

/// A check mark that plays a celebration's flourish once, when it appears. Pass a new celebration to
/// play again. Decorative: it never takes taps and is hidden from VoiceOver.
public struct CelebrationMark: View {
    let celebration: Celebration?
    let symbol: String

    public init(_ celebration: Celebration?, symbol: String = "checkmark.circle.fill") {
        self.celebration = celebration
        self.symbol = symbol
    }

    public var body: some View {
        Group {
            if let celebration {
                // A fresh view per celebration, so each one starts from the beginning.
                FlourishView(flourish: celebration.flourish, symbol: symbol)
                    .id(celebration.index)
            } else {
                Image(systemName: symbol)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct FlourishView: View {
    let flourish: Celebration.Flourish
    let symbol: String

    /// The check has landed.
    @State private var popped = false
    /// The flourish has spread out and faded.
    @State private var spread = false

    private static let colors: [Color] = [.orange, .pink, .yellow, .blue, .purple, .green]

    var body: some View {
        Image(systemName: symbol)
            .scaleEffect(flourish == .fade || popped ? 1 : 0.5)
            .opacity(flourish != .fade || popped ? 1 : 0.15)
            .background { backdrop }
            .overlay { particles }
            .onAppear {
                withAnimation(flourish == .fade ? .easeOut(duration: 0.3) : .spring(duration: 0.4, bounce: 0.55)) {
                    popped = true
                }
                withAnimation(.easeOut(duration: Celebration.duration)) {
                    spread = true
                }
            }
    }

    /// Behind the check: a rippling ring, or a still glow for Reduce Motion.
    @ViewBuilder
    private var backdrop: some View {
        switch flourish {
        case .ring:
            Circle()
                .strokeBorder(.green, lineWidth: 2)
                .scaleEffect(spread ? 2.6 : 0.9)
                .animation(.easeIn(duration: Celebration.duration)) { $0.opacity(spread ? 0 : 0.9) }
        case .fade:
            Circle()
                .fill(.green)
                .scaleEffect(1.8)
                .animation(.easeIn(duration: Celebration.duration)) { $0.opacity(spread ? 0 : 0.3) }
        case .check, .confetti, .sparkles:
            EmptyView()
        }
    }

    @ViewBuilder
    private var particles: some View {
        switch flourish {
        case .confetti:
            ZStack {
                ForEach(0..<12, id: \.self) { piece in
                    let angle = Angle.degrees(Double(piece) * 30 + Double(piece % 3) * 9)
                    let distance = 24 + Double(piece % 4) * 5
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Self.colors[piece % Self.colors.count])
                        .frame(width: 3, height: 7)
                        .rotationEffect(.degrees(spread ? Double(piece) * 47 + 180 : Double(piece) * 47))
                        .offset(x: spread ? cos(angle.radians) * distance : 0, y: spread ? sin(angle.radians) * distance : 0)
                        .animation(.easeIn(duration: Celebration.duration)) { $0.opacity(spread ? 0 : 1) }
                }
            }
        case .sparkles:
            ZStack {
                ForEach(0..<5, id: \.self) { sparkle in
                    // Fanned out above the check.
                    let angle = Angle.degrees(-90 + Double(sparkle - 2) * 35)
                    let distance = 22 + Double(sparkle % 2) * 6
                    Image(systemName: "sparkle")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.yellow)
                        .scaleEffect(spread ? 1.2 : 0.3)
                        .offset(x: spread ? cos(angle.radians) * distance : 0, y: spread ? sin(angle.radians) * distance : 0)
                        .animation(.easeIn(duration: Celebration.duration)) { $0.opacity(spread ? 0 : 1) }
                }
            }
        case .check, .ring, .fade:
            EmptyView()
        }
    }
}

extension Celebration.Haptic {
    public var feedback: SensoryFeedback {
        switch self {
        case .success: .success
        case .pop: .impact(flexibility: .rigid, intensity: 0.9)
        case .burst: .impact(weight: .heavy)
        case .rise: .increase
        }
    }
}

extension View {
    /// Plays the celebration's haptic, if it has one, whenever a new celebration arrives.
    public func celebrationFeedback(_ celebration: Celebration?) -> some View {
        sensoryFeedback(trigger: celebration) { _, new in new?.haptic?.feedback }
    }
}
