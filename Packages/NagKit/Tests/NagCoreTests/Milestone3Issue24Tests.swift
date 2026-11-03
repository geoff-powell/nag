import Foundation
import Testing
@testable import NagCore

@Suite struct Milestone3Issue24Tests {
    private func flourishes(seed: UInt64, count: Int = 400) -> [Celebration.Flourish] {
        (0..<count).map { Celebration.flourish(index: $0, seed: seed) }
    }

    @Test func sameSeedAndIndexAlwaysGiveTheSameCelebration() {
        for index in 0..<50 {
            let a = Celebration.make(index: index, seed: 42, haptics: true, reduceMotion: false)
            let b = Celebration.make(index: index, seed: 42, haptics: true, reduceMotion: false)
            #expect(a == b)
        }
    }

    @Test func firstCelebrationIsThePlainCheck() {
        for seed: UInt64 in [0, 1, 42, .max] {
            #expect(Celebration.flourish(index: 0, seed: seed) == .check)
        }
    }

    @Test func mostCelebrationsAreThePlainCheck() {
        let all = flourishes(seed: 7)
        let checks = all.filter { $0 == .check }.count
        #expect(checks > all.count / 2)
    }

    @Test func specialsVaryAndAllShowUpEventually() {
        let specials = Set(flourishes(seed: 7).filter(\.isSpecial))
        #expect(specials == Set(Celebration.Flourish.specials))
    }

    @Test func specialsNeverComeBackToBack() {
        for seed: UInt64 in [0, 1, 7, 42, 1234, .max] {
            let all = flourishes(seed: seed)
            for (previous, next) in zip(all, all.dropFirst()) {
                #expect(!(previous.isSpecial && next.isSpecial))
            }
        }
    }

    @Test func differentSeedsGiveDifferentSequences() {
        #expect(flourishes(seed: 1) != flourishes(seed: 2))
    }

    @Test func neverPicksFadeWithoutReduceMotion() {
        #expect(!flourishes(seed: 99).contains(.fade))
    }

    @Test func reduceMotionAlwaysFadesButKeepsTheHaptic() {
        for index in 0..<100 {
            let moving = Celebration.make(index: index, seed: 5, haptics: true, reduceMotion: false)
            let still = Celebration.make(index: index, seed: 5, haptics: true, reduceMotion: true)
            #expect(still.flourish == .fade)
            #expect(still.haptic == moving.haptic)
        }
    }

    @Test func hapticsOffMeansNoHaptic() {
        for index in 0..<100 {
            let celebration = Celebration.make(index: index, seed: 5, haptics: false, reduceMotion: false)
            #expect(celebration.haptic == nil)
        }
    }

    @Test func hapticFollowsTheFlourish() {
        #expect(Celebration.Flourish.check.haptic == .success)
        #expect(Celebration.Flourish.fade.haptic == .success)
        let specialHaptics = Set(Celebration.Flourish.specials.map(\.haptic))
        #expect(specialHaptics.count == Celebration.Flourish.specials.count)
        #expect(!specialHaptics.contains(.success))
    }

    @Test func celebrationsAreDistinctTriggers() {
        let first = Celebration.make(index: 1, seed: 3, haptics: true, reduceMotion: true)
        let second = Celebration.make(index: 2, seed: 3, haptics: true, reduceMotion: true)
        #expect(first != second)
    }

    @Test func playsForAtMostASecond() {
        #expect(Celebration.duration > 0)
        #expect(Celebration.duration <= 1)
    }

    @Test func hapticsDefaultOnAndDecodeFromOlderSettings() throws {
        #expect(AppSettings().haptics)
        let oldJSON = #"{ "hasOnboarded": true }"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(oldJSON.utf8))
        #expect(settings.haptics)
    }

    @Test func hapticsSettingRoundTrips() throws {
        let settings = AppSettings(haptics: false)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(!decoded.haptics)
    }

    @Test func hapticsStayOnThisDeviceWhenQuietHoursSync() {
        var settings = AppSettings(haptics: false)
        let remote = SyncedQuietHours(quietHours: QuietHours(enabled: true), updatedAt: Fixture.date(28, 9))
        settings.apply(remote)
        #expect(!settings.haptics)
        #expect(settings.syncedQuietHours == AppSettings(quietHours: QuietHours(enabled: true), quietHoursUpdatedAt: Fixture.date(28, 9)).syncedQuietHours)
    }
}
