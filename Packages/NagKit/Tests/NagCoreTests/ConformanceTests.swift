import Foundation
import Testing
@testable import NagCore

/// Runs the language-neutral fixtures in `Fixtures/conformance` against NagCore, which is the
/// reference implementation. The same files are run by the C# core and by the KMP prototype (#41).
enum Conformance {
    static let platform = "swift"

    static func url(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // NagCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // NagKit
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("Fixtures/conformance/\(name).json")
    }

    static func load<Input: Decodable & Sendable, Expect: Decodable & Sendable>(
        _ name: String, as _: Input.Type, _: Expect.Type
    ) throws -> [FixtureCase<Input, Expect>] {
        let file = try JSONDecoder().decode(
            FixtureFile<Input, Expect>.self, from: Data(contentsOf: url(name))
        )
        #expect(file.schema == 1)
        #expect(!file.cases.isEmpty)
        return file.cases.filter { $0.skip?[platform] == nil }
    }

    static func date(_ millis: Int64) -> Date {
        Date(timeIntervalSince1970: Double(millis) / 1000)
    }

    static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

struct FixtureFile<Input: Decodable & Sendable, Expect: Decodable & Sendable>: Decodable, Sendable {
    let schema: Int
    let cases: [FixtureCase<Input, Expect>]
}

struct FixtureCase<Input: Decodable & Sendable, Expect: Decodable & Sendable>: Decodable, Sendable {
    struct Override: Decodable, Sendable {
        let reason: String
        let expect: Expect
    }

    let name: String
    let input: Input
    let expect: Expect
    let overrides: [String: Override]?
    let skip: [String: String]?

    /// What this platform is expected to produce: the reference result, or a recorded difference.
    var expected: Expect { overrides?[Conformance.platform]?.expect ?? expect }
}

struct EscalationInput: Decodable, Sendable {
    let mode: Escalation
    let baseSeconds: Double
    let overdueSeconds: Double
}

struct EscalationExpect: Decodable, Sendable {
    let intervalSeconds: Double
    let nextTighteningSeconds: Double?
}

struct TaskFixture: Codable, Equatable, Sendable {
    let startAt: Int64
    let completed: Bool
    let snoozeMinutes: Int
    let maxSnoozes: Int?
    let snoozeCount: Int
    let snoozedUntil: Int64?

    var task: NagTask {
        let start = Conformance.date(startAt)
        var task = NagTask(
            title: "Fixture",
            startAt: start,
            style: NagStyle(snoozeMinutes: snoozeMinutes, maxSnoozes: maxSnoozes),
            now: start
        )
        task.snoozeCount = snoozeCount
        task.snoozedUntil = snoozedUntil.map(Conformance.date)
        if completed { task.completedAt = start }
        return task
    }

    init(_ task: NagTask) {
        startAt = Conformance.millis(task.startAt)
        completed = task.completedAt != nil
        snoozeMinutes = task.style.snoozeMinutes
        maxSnoozes = task.style.maxSnoozes
        snoozeCount = task.snoozeCount
        snoozedUntil = task.snoozedUntil.map(Conformance.millis)
    }
}

struct SnoozeInput: Decodable, Sendable {
    let op: String
    let now: Int64
    let task: TaskFixture
}

struct SnoozeExpect: Decodable, Sendable {
    let canSnooze: Bool?
    let task: TaskFixture
}

@Suite struct ConformanceTests {
    @Test func escalationMatchesSharedFixtures() throws {
        let cases = try Conformance.load("escalation", as: EscalationInput.self, EscalationExpect.self)
        for fixture in cases {
            let input = fixture.input
            let expected = fixture.expected
            let interval = input.mode.interval(base: input.baseSeconds, overdue: input.overdueSeconds)
            let next = input.mode.nextTightening(base: input.baseSeconds, overdue: input.overdueSeconds)
            #expect(abs(interval - expected.intervalSeconds) < 1e-9, "\(fixture.name): interval \(interval)")
            #expect(next == expected.nextTighteningSeconds, "\(fixture.name): next \(String(describing: next))")
        }
    }

    @Test func snoozeMatchesSharedFixtures() throws {
        let cases = try Conformance.load("snooze", as: SnoozeInput.self, SnoozeExpect.self)
        for fixture in cases {
            let now = Conformance.date(fixture.input.now)
            var task = fixture.input.task.task
            switch fixture.input.op {
            case "snooze":
                #expect(task.canSnooze(at: now) == fixture.expected.canSnooze, "\(fixture.name): canSnooze")
                task.snooze(at: now)
            case "complete":
                task.complete(at: now, calendar: Fixture.calendar)
            default:
                Issue.record("\(fixture.name): unknown op \(fixture.input.op)")
            }
            let actual = TaskFixture(task)
            #expect(actual == fixture.expected.task, "\(fixture.name): \(actual)")
        }
    }
}
