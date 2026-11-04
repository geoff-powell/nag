import Foundation
import NagCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether on-device help can be offered.
public enum NagAssistantStatus: Hashable, Sendable {
    case available
    /// The device supports Apple Intelligence, but it's switched off in Settings.
    case notEnabled
    /// Apple Intelligence is on, but the model is still downloading.
    case notReady
    /// The device, OS or region doesn't support it. Nothing is shown.
    case unsupported
}

extension NagAssistantStatus {
    /// Explains the Apple Intelligence setting.
    public var settingsFooter: String {
        #if os(macOS)
        let device = "this Mac"
        let settings = "System Settings"
        #else
        let device = "this iPhone"
        let settings = "Settings"
        #endif
        return switch self {
        case .available:
            "Suggests a first step, breaks a nag into steps, reads quick-add text like “dentist thu 3pm”, and writes fresh wording in each nag's tone. It all runs on \(device); nothing is sent anywhere."
        case .notEnabled:
            "Turn on Apple Intelligence in \(settings) to get first steps, steps, quick add and fresh wording, all on \(device)."
        case .notReady:
            "Apple Intelligence is still getting ready. Try again in a little while."
        case .unsupported:
            ""
        }
    }
}

/// On-device help with writing nags. Everything runs on device through Apple Intelligence; nothing is
/// sent anywhere.
///
/// Every method quietly returns nothing when the model is unavailable or a request fails (a guardrail,
/// the context window, an OS update changing output), so callers just keep what they had. What does
/// come back has already been checked by `AssistantOutput`.
public protocol NagAssisting: Sendable {
    var status: NagAssistantStatus { get }
    /// One small first action for the notes.
    func firstStep(title: String, notes: String) async -> String?
    /// The nag broken into small steps, in order.
    func steps(title: String, notes: String) async -> [RoutineStep]
    /// A few alternative notification lines in `tone`.
    func wording(title: String, notes: String, tone: NagTone) async -> [String]
    /// What a typed or spoken line like "dentist thu 3pm" describes, in relative terms. Resolve it with
    /// `QuickAddFields.request(now:calendar:)`.
    func quickAdd(_ text: String) async -> QuickAddFields?
}

extension NagAssisting {
    public var isAvailable: Bool { status == .available }
}

public enum NagAssistant {
    /// The on-device assistant where the OS has the Foundation Models framework, otherwise one that's
    /// never available.
    public static func make() -> any NagAssisting {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            return OnDeviceNagAssistant()
        }
        #endif
        return UnavailableNagAssistant()
    }
}

/// Offers nothing. Used before iOS and macOS 26, and in UI tests.
public struct UnavailableNagAssistant: NagAssisting {
    public init() {}
    public var status: NagAssistantStatus { .unsupported }
    public func firstStep(title: String, notes: String) async -> String? { nil }
    public func steps(title: String, notes: String) async -> [RoutineStep] { [] }
    public func wording(title: String, notes: String, tone: NagTone) async -> [String] { [] }
    public func quickAdd(_ text: String) async -> QuickAddFields? { nil }
}

#if canImport(FoundationModels)

/// Uses the on-device system language model. Each request gets a fresh session with short
/// instructions, so prompts stay well inside the 4,096-token context window.
@available(iOS 26, macOS 26, *)
struct OnDeviceNagAssistant: NagAssisting {
    /// Long notes are cut so a prompt can't run past the context window.
    static let maxNotesLength = 600

    var status: NagAssistantStatus {
        switch SystemLanguageModel.default.availability {
        case .available: .available
        case .unavailable(.appleIntelligenceNotEnabled): .notEnabled
        case .unavailable(.modelNotReady): .notReady
        case .unavailable: .unsupported
        }
    }

    func firstStep(title: String, notes: String) async -> String? {
        let result = await generate(
            FirstStepSuggestion.self,
            instructions: """
            You help people with ADHD start tasks they keep putting off. Suggest the single smallest \
            physical first action for the task, something that takes under two minutes. Write it as a \
            short instruction in plain words, without a greeting or explanation.
            """,
            prompt: Self.describe(title: title, notes: notes)
        )
        return result.flatMap { AssistantOutput.firstStep($0.step, title: title) }
    }

    func steps(title: String, notes: String) async -> [RoutineStep] {
        let result = await generate(
            StepPlan.self,
            instructions: """
            You help people with ADHD break a task into small concrete steps, in the order they're \
            done. Each step is a short instruction of a few words. Estimate each step in minutes. Use \
            between 3 and 8 steps unless the task really needs more.
            """,
            prompt: Self.describe(title: title, notes: notes)
        )
        return AssistantOutput.steps(result?.steps.map { SuggestedStep(title: $0.title, estimateMinutes: $0.minutes) } ?? [])
    }

    func wording(title: String, notes: String, tone: NagTone) async -> [String] {
        let result = await generate(
            WordingPool.self,
            instructions: """
            You write short reminder notifications for an app that nags people until a task is done. \
            Tone: \(Self.describe(tone)) Each line is one or two short sentences, at most 100 \
            characters, and is different from the others. Don't use emoji, links or the person's name.
            """,
            prompt: Self.describe(title: title, notes: notes)
        )
        return AssistantOutput.wording(result?.lines ?? [], title: title)
    }

    func quickAdd(_ text: String) async -> QuickAddFields? {
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        guard !text.isEmpty,
              let result = await generate(
                  QuickAddParse.self,
                  instructions: """
                  You read a short note someone typed or said to set a reminder, such as "dentist thu \
                  3pm" or "take bins out every tuesday at 7pm", and pull out what to do and when. Only \
                  fill in a field when the note says it. Never work out dates yourself: give the \
                  weekday, or days from today, or the month and day, exactly as said. Use 24-hour time.
                  """,
                  prompt: text
              )
        else { return nil }
        return QuickAddFields(
            title: result.title,
            daysFromToday: result.daysFromToday,
            weekday: result.weekday.flatMap(QuickAddFields.weekday(named:)),
            month: result.month,
            day: result.day,
            hour: result.hour,
            minute: result.minute,
            repeatKind: result.repeatKind,
            repeatEvery: result.repeatEvery
        )
    }

    /// Runs one request in its own session. Any failure (unavailable, guardrail, context window,
    /// unsupported language) returns `nil` so the caller falls back to what it had.
    private func generate<Content: Generable>(
        _ type: Content.Type,
        instructions: String,
        prompt: String
    ) async -> Content? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        do {
            return try await session.respond(to: prompt, generating: type).content
        } catch {
            return nil
        }
    }

    private static func describe(title: String, notes: String) -> String {
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = "Task: \(title.trimmingCharacters(in: .whitespacesAndNewlines))"
        return notes.isEmpty ? task : "\(task)\nNotes: \(notes.prefix(maxNotesLength))"
    }

    private static func describe(_ tone: NagTone) -> String {
        switch tone {
        case .gentle: "gentle and warm. Encourage without guilt or pressure."
        case .standard: "friendly but firm, a little cheeky."
        case .pushy: "blunt and direct. Press them to act right now, without being cruel."
        }
    }
}

@available(iOS 26, macOS 26, *)
@Generable
struct FirstStepSuggestion {
    @Guide(description: "The smallest first action, under 15 words")
    var step: String
}

@available(iOS 26, macOS 26, *)
@Generable
struct StepPlan {
    @Guide(description: "The steps, in order", .count(1...12))
    var steps: [PlannedStep]
}

@available(iOS 26, macOS 26, *)
@Generable
struct PlannedStep {
    @Guide(description: "A short instruction, under 8 words")
    var title: String
    @Guide(description: "Roughly how many minutes the step takes", .range(1...180))
    var minutes: Int
}

@available(iOS 26, macOS 26, *)
@Generable
struct WordingPool {
    @Guide(description: "Alternative reminder lines", .count(4...8))
    var lines: [String]
}

@available(iOS 26, macOS 26, *)
@Generable
struct QuickAddParse {
    @Guide(description: "What to do, as a short title without the time or repeat words")
    var title: String
    @Guide(description: "0 for today, 1 for tomorrow, and so on. Only when the note says today, tonight or tomorrow, or in N days")
    var daysFromToday: Int?
    @Guide(description: "The weekday named in the note", .anyOf(["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]))
    var weekday: String?
    @Guide(description: "Month number 1-12, only when the note names a month", .range(1...12))
    var month: Int?
    @Guide(description: "Day of the month 1-31, only when the note gives a date", .range(1...31))
    var day: Int?
    @Guide(description: "Hour in 24-hour time, 0-23", .range(0...23))
    var hour: Int?
    @Guide(description: "Minute, 0-59", .range(0...59))
    var minute: Int?
    @Guide(description: "How it repeats, only when the note says so", .anyOf(QuickAddFields.repeatKinds))
    var repeatKind: String?
    @Guide(description: "Days between repeats, only for everyNDays", .range(2...365))
    var repeatEvery: Int?
}

#endif
