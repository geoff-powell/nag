import Foundation
import NagCore
import NagRules

// Minimal Swift consumer of the KMP prototype (#41). It calls the typed Kotlin API exported through
// Objective-C:
// 1. Runs Fixtures/conformance through that API.
// 2. Compares the prototype with Swift NagCore on seeded random inputs.
// Exits with status 1 on any mismatch.

let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // NagRulesConsumer
    .deletingLastPathComponent() // Sources
    .deletingLastPathComponent() // swift
    .deletingLastPathComponent() // consumers
    .deletingLastPathComponent() // kmp
    .deletingLastPathComponent()
let fixtures = repository.appendingPathComponent("Fixtures/conformance")
var failures: [String] = []

@MainActor func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    if !condition { failures.append(message()) }
}

func cases(_ name: String) throws -> [[String: Any]] {
    let data = try Data(contentsOf: fixtures.appendingPathComponent("\(name).json"))
    let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    return (root["cases"] as! [[String: Any]]).filter { ($0["skip"] as? [String: Any])?["kotlin"] == nil }
}

func number(_ value: Any?) -> NSNumber? { value as? NSNumber }

func snoozeState(_ task: [String: Any]) -> SnoozeState {
    SnoozeState(
        startAtMillis: number(task["startAt"])!.int64Value,
        completed: task["completed"] as! Bool,
        snoozeMinutes: number(task["snoozeMinutes"])!.int32Value,
        maxSnoozes: number(task["maxSnoozes"]).map { KotlinInt(int: $0.int32Value) },
        snoozeCount: number(task["snoozeCount"])!.int32Value,
        snoozedUntilMillis: number(task["snoozedUntil"]).map { KotlinLong(longLong: $0.int64Value) }
    )
}

func same(_ state: SnoozeState, _ task: [String: Any]) -> Bool {
    state.startAtMillis == number(task["startAt"])!.int64Value
        && state.completed == (task["completed"] as! Bool)
        && state.snoozeMinutes == number(task["snoozeMinutes"])!.int32Value
        && state.maxSnoozes?.int32Value == number(task["maxSnoozes"])?.int32Value
        && state.snoozeCount == number(task["snoozeCount"])!.int32Value
        && state.snoozedUntilMillis?.int64Value == number(task["snoozedUntil"])?.int64Value
}

// 1. Shared fixtures through the typed API.
var matched = 0
for fixture in try cases("escalation") {
    let input = fixture["input"] as! [String: Any]
    let expect = fixture["expect"] as! [String: Any]
    let mode = NagRules.Escalation.companion.parse(name: input["mode"] as! String)
    let base = number(input["baseSeconds"])!.doubleValue
    let overdue = number(input["overdueSeconds"])!.doubleValue
    let interval = mode.interval(baseSeconds: base, overdueSeconds: overdue)
    let next = mode.nextTightening(baseSeconds: base, overdueSeconds: overdue)?.doubleValue
    check(abs(interval - number(expect["intervalSeconds"])!.doubleValue) < 1e-9, "\(fixture["name"]!): interval \(interval)")
    check(next == number(expect["nextTighteningSeconds"])?.doubleValue, "\(fixture["name"]!): next \(String(describing: next))")
    matched += 1
}
for fixture in try cases("snooze") {
    let input = fixture["input"] as! [String: Any]
    let expect = fixture["expect"] as! [String: Any]
    let now = number(input["now"])!.int64Value
    let state = snoozeState(input["task"] as! [String: Any])
    let after: SnoozeState
    if input["op"] as! String == "snooze" {
        check(state.canSnooze(nowMillis: now) == (expect["canSnooze"] as! Bool), "\(fixture["name"]!): canSnooze")
        after = state.snoozed(nowMillis: now) ?? state
    } else {
        after = state.complete()
    }
    check(same(after, expect["task"] as! [String: Any]), "\(fixture["name"]!): \(after)")
    matched += 1
}
print("Fixtures: \(matched) cases through the typed Swift API")

// 2. Differential check against NagCore on seeded random inputs.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

var random = SplitMix64(state: 41)
let modes: [(NagCore.Escalation, NagRules.Escalation)] = [
    (.steady, .steady), (.gentle, .gentle), (.relentless, .relentless),
]
let iterations = 20_000
for _ in 0..<iterations {
    let (swiftMode, kotlinMode) = modes.randomElement(using: &random)!
    let base = Bool.random(using: &random)
        ? Double(Int.random(in: 0...1440, using: &random) * 60)
        : Double.random(in: 0...90_000, using: &random)
    let overdue = Double.random(in: -100_000...5_000_000, using: &random)
    let swiftInterval = swiftMode.interval(base: base, overdue: overdue)
    let kotlinInterval = kotlinMode.interval(baseSeconds: base, overdueSeconds: overdue)
    check(swiftInterval == kotlinInterval, "interval \(swiftMode) \(base) \(overdue): \(swiftInterval) vs \(kotlinInterval)")
    let swiftNext = swiftMode.nextTightening(base: base, overdue: overdue)
    let kotlinNext = kotlinMode.nextTightening(baseSeconds: base, overdueSeconds: overdue)?.doubleValue
    check(swiftNext == kotlinNext, "next \(swiftMode) \(base) \(overdue): \(String(describing: swiftNext)) vs \(String(describing: kotlinNext))")
}

let now: Int64 = 1_793_178_000_000
for _ in 0..<iterations {
    let startAt = now + Int64.random(in: -7_200...7_200, using: &random) * 1000
    let completed = Int.random(in: 0..<5, using: &random) == 0
    let snoozeMinutes = Int.random(in: 1...1440, using: &random)
    let maxSnoozes: Int? = Bool.random(using: &random) ? Int.random(in: 0...5, using: &random) : nil
    let snoozeCount = Int.random(in: 0...7, using: &random)
    let snoozedUntil: Int64? = Bool.random(using: &random) ? now + Int64.random(in: -3_600...3_600, using: &random) * 1000 : nil

    let start = Date(timeIntervalSince1970: Double(startAt) / 1000)
    var task = NagTask(title: "Fuzz", startAt: start, style: NagStyle(snoozeMinutes: snoozeMinutes, maxSnoozes: maxSnoozes), now: start)
    task.snoozeCount = snoozeCount
    task.snoozedUntil = snoozedUntil.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    if completed { task.completedAt = start }
    let state = SnoozeState(
        startAtMillis: startAt, completed: completed, snoozeMinutes: Int32(snoozeMinutes),
        maxSnoozes: maxSnoozes.map { KotlinInt(int: Int32($0)) }, snoozeCount: Int32(snoozeCount),
        snoozedUntilMillis: snoozedUntil.map { KotlinLong(longLong: $0) }
    )
    let date = Date(timeIntervalSince1970: Double(now) / 1000)
    check(task.canSnooze(at: date) == state.canSnooze(nowMillis: now), "canSnooze \(state)")
    check(task.isSnoozed(at: date) == state.isSnoozed(nowMillis: now), "isSnoozed \(state)")
    let snoozed = task.snooze(at: date)
    let kotlin = state.snoozed(nowMillis: now)
    check(snoozed == (kotlin != nil), "snoozed \(state)")
    if let kotlin {
        check(Int64((task.snoozedUntil!.timeIntervalSince1970 * 1000).rounded()) == kotlin.snoozedUntilMillis?.int64Value, "snoozedUntil \(state)")
        check(task.snoozeCount == Int(kotlin.snoozeCount), "snoozeCount \(state)")
    }
}
print("Differential: \(iterations) escalation and \(iterations) snooze inputs compared with NagCore")

if failures.isEmpty {
    print("All checks passed.")
} else {
    failures.prefix(20).forEach { print("FAIL \($0)") }
    print("\(failures.count) mismatch(es).")
    exit(1)
}
