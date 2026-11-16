import Foundation

// MARK: - Model output

/// A step the on-device model suggested, before it's checked.
public struct SuggestedStep: Hashable, Sendable {
    public var title: String
    public var estimateMinutes: Int?

    public init(title: String, estimateMinutes: Int? = nil) {
        self.title = title
        self.estimateMinutes = estimateMinutes
    }
}

/// Checks and tidies what the on-device model writes before any of it reaches a nag.
///
/// Model output can change with OS updates, so none of it is trusted as-is: text is trimmed, list
/// markers and wrapping quotes are dropped, lengths and counts are capped, and anything empty or
/// repeated is thrown away.
public enum AssistantOutput {
    public static let maxSteps = 12
    public static let stepEstimates = 1...180
    public static let maxStepLength = 80
    public static let maxFirstStepLength = 160
    public static let maxTitleLength = 120
    public static let maxWordingLines = 8
    /// Longer lines are dropped rather than cut, since half a sentence makes a poor notification.
    public static let maxWordingLength = 120

    /// A first tiny step for the notes, or `nil` when the suggestion is empty or just repeats the title.
    public static func firstStep(_ raw: String, title: String) -> String? {
        guard let step = clean(raw, limit: maxFirstStepLength), !same(step, title) else { return nil }
        return step
    }

    /// Up to `maxSteps` steps, in order, without blanks or repeats. Estimates outside 1–180 minutes are
    /// dropped rather than guessed.
    public static func steps(_ raw: [SuggestedStep]) -> [RoutineStep] {
        var seen = Set<String>()
        var result: [RoutineStep] = []
        for suggestion in raw {
            guard let title = clean(suggestion.title, limit: maxStepLength),
                  seen.insert(key(title)).inserted
            else { continue }
            let estimate = suggestion.estimateMinutes.flatMap { stepEstimates.contains($0) ? $0 : nil }
            result.append(RoutineStep(title: title, estimateMinutes: estimate))
            if result.count == maxSteps { break }
        }
        return result
    }

    /// Notification lines without blanks, repeats, links, over-long lines or lines that only repeat
    /// the title.
    public static func wording(_ raw: [String], title: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for line in raw {
            guard let line = clean(line, limit: nil),
                  line.count <= maxWordingLength,
                  !line.localizedCaseInsensitiveContains("http"),
                  !same(line, title),
                  seen.insert(key(line)).inserted
            else { continue }
            result.append(line)
            if result.count == maxWordingLines { break }
        }
        return result
    }

    /// A nag title: one line, at most `maxTitleLength` characters.
    public static func title(_ raw: String) -> String? {
        clean(raw, limit: maxTitleLength)
    }

    /// First line, without list markers or wrapping quotes, with runs of spaces collapsed. Cut at a
    /// word boundary when it's longer than `limit`.
    static func clean(_ raw: String, limit: Int?) -> String? {
        let firstLine = raw
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        var text = firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let marker = text.firstMatch(of: /^(?:[-*•–]|\d{1,2}[.)]|step\s+\d{1,2}[:.)]?)\s*/.ignoresCase()) {
            text.removeSubrange(marker.range)
        }
        let quotes: Set<Character> = ["\"", "'", "“", "”", "‘", "’", "`"]
        while let first = text.first, let last = text.last, text.count >= 2, quotes.contains(first), quotes.contains(last) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if let limit, text.count > limit {
            let cut = text.prefix(limit)
            let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
            text = atWord.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        }
        return text.isEmpty ? nil : text
    }

    private static func key(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        key(a) == key(b)
    }
}

// MARK: - Quick add

/// What the on-device model read out of typed or spoken text such as "dentist thu 3pm", in relative
/// terms. `request(now:calendar:)` turns it into a date, so the model never does date arithmetic.
public struct QuickAddFields: Hashable, Sendable {
    public var title: String
    /// 0 for today, 1 for tomorrow.
    public var daysFromToday: Int?
    /// Calendar weekday number (1 = Sunday … 7 = Saturday).
    public var weekday: Int?
    public var month: Int?
    public var day: Int?
    /// 0–23.
    public var hour: Int?
    /// 0–59.
    public var minute: Int?
    /// `once`, `daily`, `weekdays`, `weekly`, `monthly` or `everyNDays`.
    public var repeatKind: String?
    /// Days between occurrences for `everyNDays`.
    public var repeatEvery: Int?

    public init(
        title: String,
        daysFromToday: Int? = nil,
        weekday: Int? = nil,
        month: Int? = nil,
        day: Int? = nil,
        hour: Int? = nil,
        minute: Int? = nil,
        repeatKind: String? = nil,
        repeatEvery: Int? = nil
    ) {
        self.title = title
        self.daysFromToday = daysFromToday
        self.weekday = weekday
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.repeatKind = repeatKind
        self.repeatEvery = repeatEvery
    }

    /// The repeat kinds the model may choose from. Custom schedules aren't offered.
    public static let repeatKinds = ["once", "daily", "weekdays", "weekly", "monthly", "everyNDays"]

    /// "monday" … "sunday", "thu", "Thurs." to a weekday number.
    public static func weekday(named name: String) -> Int? {
        let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        let short = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(3)
        return names.firstIndex(of: String(short)).map { $0 + 1 }
    }
}

public enum QuickAddError: Error, Hashable, Sendable {
    case missingTitle
    /// An hour or minute out of range, or a date that doesn't exist, like 30 February.
    case invalidDate
    /// Today at a time that has already gone.
    case inThePast
}

extension QuickAddError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingTitle: "Couldn't find what to nag you about."
        case .invalidDate: "Couldn't work out when."
        case .inThePast: "That time has already passed today."
        }
    }
}

extension QuickAddFields {
    /// The nag this describes, resolved against `now`. Nothing is saved: the result goes to the editor
    /// for the user to check.
    ///
    /// - A time with no day is the next time it comes round: today if it's still ahead, else tomorrow.
    /// - A day with no time is 9 AM, or now if that day is today.
    /// - A weekday that is today means today if the time is still ahead (or no time was given),
    ///   otherwise the same day next week.
    /// - A month and day that have passed this year mean next year. A day with no month means the
    ///   next time that day of the month comes round.
    /// - "Today" at a time that has gone is rejected rather than moved.
    /// - Repeats map only to rules Nag supports; anything else is a one-off.
    public func request(now: Date, calendar: Calendar) throws(QuickAddError) -> NagRequest {
        guard let title = AssistantOutput.title(title) else { throw .missingTitle }
        let time = try timeOfDay()
        let today = calendar.startOfDay(for: now)

        var startAt: Date?
        if let day {
            startAt = try nextDate(month: month, day: day, time: time, now: now, calendar: calendar)
        } else if let daysFromToday {
            guard (0...366).contains(daysFromToday),
                  let date = calendar.date(byAdding: .day, value: daysFromToday, to: today)
            else { throw .invalidDate }
            if daysFromToday == 0, time == nil {
                startAt = nil
            } else {
                let start = try at(time ?? Self.defaultTime, on: date, calendar: calendar)
                if start <= now { throw .inThePast }
                startAt = start
            }
        } else if let weekday {
            guard (1...7).contains(weekday) else { throw .invalidDate }
            let todayWeekday = calendar.component(.weekday, from: now)
            if weekday == todayWeekday {
                if let time {
                    let todayAt = try at(time, on: today, calendar: calendar)
                    startAt = try todayAt > now ? todayAt : at(time, on: adding(7, to: today, calendar), calendar: calendar)
                } else {
                    startAt = nil
                }
            } else {
                let ahead = (weekday - todayWeekday + 7) % 7
                startAt = try at(time ?? Self.defaultTime, on: adding(ahead, to: today, calendar), calendar: calendar)
            }
        } else if let time {
            let todayAt = try at(time, on: today, calendar: calendar)
            startAt = try todayAt > now ? todayAt : at(time, on: adding(1, to: today, calendar), calendar: calendar)
        }

        var request = NagRequest(title: title, startAt: startAt)
        switch repeatKind.map(Self.normalized) {
        case "daily": request.repeatRule = .daily
        case "weekdays": request.repeatRule = .weekdays
        case "weekly": request.repeatRule = .weekly
        case "monthly":
            request.repeatRule = .monthly
            request.monthDay = calendar.component(.day, from: startAt ?? now)
        case "everyndays":
            switch repeatEvery {
            case 1: request.repeatRule = .daily
            case let every? where (2...365).contains(every):
                request.repeatRule = .everyNDays
                request.repeatEvery = every
            default: request.repeatRule = .never
            }
        default: request.repeatRule = .never
        }
        return request
    }

    /// What the editor should open with for typed `text`: what the model read, or, when it read nothing
    /// usable (no answer, a time that's gone, a date that doesn't exist), the text itself as the title so
    /// nothing typed is lost. The user still checks it in the editor before anything is saved.
    public static func request(for text: String, fields: QuickAddFields?, now: Date, calendar: Calendar) -> NagRequest {
        if let fields, let request = try? fields.request(now: now, calendar: calendar) { return request }
        return NagRequest(title: AssistantOutput.title(text) ?? "")
    }

    private static let defaultTime = (hour: 9, minute: 0)

    private static func normalized(_ kind: String) -> String {
        kind.lowercased().filter(\.isLetter)
    }

    private func timeOfDay() throws(QuickAddError) -> (hour: Int, minute: Int)? {
        guard let hour else {
            if minute != nil { throw .invalidDate }
            return nil
        }
        let minute = minute ?? 0
        guard (0...23).contains(hour), (0...59).contains(minute) else { throw .invalidDate }
        return (hour, minute)
    }

    private func adding(_ count: Int, to date: Date, _ calendar: Calendar) throws(QuickAddError) -> Date {
        guard let result = calendar.date(byAdding: .day, value: count, to: date) else { throw .invalidDate }
        return result
    }

    private func at(_ time: (hour: Int, minute: Int), on date: Date, calendar: Calendar) throws(QuickAddError) -> Date {
        guard let result = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: date) else {
            throw .invalidDate
        }
        return result
    }

    /// The next `day` of `month` (or of any month) at `time`, from today on.
    private func nextDate(
        month: Int?,
        day: Int,
        time: (hour: Int, minute: Int)?,
        now: Date,
        calendar: Calendar
    ) throws(QuickAddError) -> Date? {
        guard (1...31).contains(day), month.map({ (1...12).contains($0) }) ?? true else { throw .invalidDate }
        let current = calendar.dateComponents([.year, .month], from: now)
        guard let year = current.year, let thisMonth = current.month else { throw .invalidDate }
        let today = calendar.startOfDay(for: now)
        // Look ahead far enough to find a 29 February, or the next month with a 31st.
        let candidates: [(year: Int, month: Int)] = if let month {
            (0...8).map { (year + $0, month) }
        } else {
            (0...12).map { offset in
                let index = thisMonth - 1 + offset
                return (year + index / 12, index % 12 + 1)
            }
        }
        for candidate in candidates {
            let parts = DateComponents(year: candidate.year, month: candidate.month, day: day)
            guard let date = calendar.date(from: parts),
                  calendar.component(.day, from: date) == day,
                  date >= today
            else { continue }
            if date == today, time == nil { return nil }
            let start = try at(time ?? Self.defaultTime, on: date, calendar: calendar)
            if start > now { return start }
        }
        throw .invalidDate
    }
}

// MARK: - Varied wording

/// Extra notification lines for one nag, written on this device in the nag's tone.
///
/// Kept in this device's state, not in the synced nag: builds that don't know about wording drop
/// fields they don't recognize when they rewrite a nag, and the lines are cheap to write again.
public struct NagWording: Codable, Hashable, Sendable {
    public var tone: NagTone
    public var lines: [String]
    /// The title the lines were written for. Renaming the nag goes back to the built-in wording until
    /// new lines are written.
    public var title: String
    public var createdAt: Date

    public init(tone: NagTone, lines: [String], title: String, createdAt: Date) {
        self.tone = tone
        self.lines = lines
        self.title = title
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case tone, lines, title, createdAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tone = (try? c.decodeIfPresent(NagTone.self, forKey: .tone)) ?? .standard
        lines = try c.decodeIfPresent([String].self, forKey: .lines) ?? []
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
    }

    /// Whether these lines still fit `task` when nagging in `tone`.
    public func applies(to task: NagTask, tone: NagTone) -> Bool {
        !lines.isEmpty && self.tone == tone
            && title.trimmingCharacters(in: .whitespacesAndNewlines) == task.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension NagState {
    /// The tone `task`'s notifications use.
    public func tone(for task: NagTask) -> NagTone {
        task.style.tone ?? settings.nagTone
    }

    /// True when `task` has no lines written for its current title and tone.
    public func needsWording(_ task: NagTask) -> Bool {
        wording[task.id.uuidString]?.applies(to: task, tone: tone(for: task)) != true
    }

    /// Stores lines for a nag, checked first. Lines for nags that no longer exist are dropped.
    public mutating func setWording(_ lines: [String], for taskID: UUID, tone: NagTone, now: Date) {
        let known = Set(tasks.map(\.id.uuidString))
        wording = wording.filter { known.contains($0.key) }
        guard let task = task(taskID) else { return }
        let checked = AssistantOutput.wording(lines, title: task.title)
        guard !checked.isEmpty else { return }
        wording[taskID.uuidString] = NagWording(tone: tone, lines: checked, title: task.title, createdAt: now)
    }
}

extension NagMessages {
    /// The written line for notification `number`, if it gets one. Only every other nag from the third
    /// on uses one, so the built-in lines, which get firmer the longer a nag waits, still come through.
    static func pooledLine(_ pool: [String]?, number: Int) -> String? {
        guard let pool, !pool.isEmpty, number >= 3, number % 2 == 1 else { return nil }
        return pool[(number / 2 - 1) % pool.count]
    }

    /// The written line for a repeating notification at `tier`, if it gets one: tiers 0 and 2, so the
    /// firmest wording is kept for the longest waits.
    static func pooledRepeatingLine(_ pool: [String]?, tier: Int) -> String? {
        guard let pool, !pool.isEmpty, tier % 2 == 0, tier < 3 else { return nil }
        return pool[(tier / 2) % pool.count]
    }
}
