/// The small reward played when a nag is finished or a lock unlocks from the app.
///
/// Most completions get the plain check. Now and then one gets a bigger flourish, so the reward doesn't
/// go stale. The choice is a pure function of a per-launch seed and a running count, so it's
/// repeatable in tests and never plays two special flourishes in a row.
public struct Celebration: Hashable, Sendable {
    public enum Flourish: String, CaseIterable, Sendable {
        /// The check pops in. The usual one.
        case check
        /// A few bits of confetti burst out of the check.
        case confetti
        /// Sparkles drift out from the check.
        case sparkles
        /// A ring ripples out from the check.
        case ring
        /// Reduce Motion: the check fades in with a soft glow, nothing moves or scales.
        case fade

        /// The occasional flourishes that vary the reward.
        public static let specials: [Flourish] = [.confetti, .sparkles, .ring]

        public var isSpecial: Bool { Self.specials.contains(self) }

        /// The haptic that goes with this flourish, when haptics are on.
        public var haptic: Haptic {
            switch self {
            case .check, .fade: .success
            case .confetti: .burst
            case .sparkles: .rise
            case .ring: .pop
            }
        }
    }

    public enum Haptic: String, CaseIterable, Sendable {
        /// The standard success notification.
        case success
        /// A firmer single tap.
        case pop
        /// A heavier thump, for confetti.
        case burst
        /// A rising tick, for sparkles.
        case rise
    }

    /// Which celebration this is in the session. Two celebrations are never equal, so views can use
    /// one as an animation or haptic trigger.
    public let index: Int
    public let flourish: Flourish
    /// Nil when haptics are turned off.
    public let haptic: Haptic?

    public init(index: Int, flourish: Flourish, haptic: Haptic?) {
        self.index = index
        self.flourish = flourish
        self.haptic = haptic
    }

    /// How long a flourish plays, in seconds. Short enough to finish before the next tap.
    public static let duration: Double = 0.9

    /// Roughly one celebration in `specialOdds` gets a special flourish.
    public static let specialOdds: UInt64 = 4

    /// The celebration for the `index`th completion of a session.
    public static func make(index: Int, seed: UInt64, haptics: Bool, reduceMotion: Bool) -> Celebration {
        let chosen = flourish(index: index, seed: seed)
        return Celebration(
            index: index,
            flourish: reduceMotion ? .fade : chosen,
            haptic: haptics ? chosen.haptic : nil
        )
    }

    /// The flourish for the `index`th completion, ignoring Reduce Motion. Special only when this roll
    /// hits and the previous one didn't, so specials never come back to back.
    public static func flourish(index: Int, seed: UInt64) -> Flourish {
        guard index > 0, isSpecialRoll(index: index, seed: seed), !isSpecialRoll(index: index - 1, seed: seed) else {
            return .check
        }
        let pick = Int(roll(index: index, seed: seed) / specialOdds % UInt64(Flourish.specials.count))
        return Flourish.specials[pick]
    }

    private static func isSpecialRoll(index: Int, seed: UInt64) -> Bool {
        roll(index: index, seed: seed) % specialOdds == 0
    }

    /// SplitMix64 of the seed and index: cheap, stable across platforms and runs.
    private static func roll(index: Int, seed: UInt64) -> UInt64 {
        var z = seed &+ UInt64(bitPattern: Int64(index)) &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
