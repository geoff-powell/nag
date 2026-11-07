import Foundation

/// A start time in the words someone says to Siri, in answer to "When should I start nagging?", or in the
/// date components Siri hears in a request like "Nag me to take my meds at 8".
public enum SpokenStart {
    /// When `answer` says to start, or `nil` to start now: a blank answer, "now" or "right away".
    ///
    /// Reads delays ("in 20 minutes", "in an hour"), clock times ("8", "8:30", "8 PM", "noon"), "tonight",
    /// "tomorrow" and weekdays ("Friday at 5"), and hands anything else ("the day after tomorrow") to the
    /// system's date detection. A day alone starts at 9 AM, like a `nag://add` date. A time without AM or
    /// PM is the next time it comes round, or on another day, the one in waking hours. Throws for a time
    /// that has passed, as well as for answers it can't read. English only, like the rest of Nag.
    public static func date(from answer: String, now: Date, calendar: Calendar) throws(NagRequestError) -> Date? {
        let text = normalized(answer)
        if text.isEmpty || nowPhrases.contains(text) { return nil }
        if let delay = delay(text) { return now.addingTimeInterval(delay) }
        if let date = dayAndTime(text, now: now, calendar: calendar) { return date }
        if let date = detectedDate(text), date > now.addingTimeInterval(-60) { return date }
        throw .invalidValue(parameter: "start time", value: answer.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// When Siri's `components` say to start: a full date as given, or else the next time that matches,
    /// such as the next 8:00 for an hour alone. A day with no time takes the time from the repeat `rule`,
    /// as in "every day at 8 starting Friday", or else starts at 9 AM, like a `nag://add` date.
    public static func date(
        from components: DateComponents,
        repeating rule: Calendar.RecurrenceRule? = nil,
        now: Date,
        calendar: Calendar
    ) throws(NagRequestError) -> Date {
        var calendar = components.calendar ?? calendar
        if let timeZone = components.timeZone { calendar.timeZone = timeZone }
        var parts = components
        parts.calendar = nil
        parts.timeZone = nil
        if parts.hour == nil, parts.minute == nil {
            if let rule, rule.hours.count == 1, rule.minutes.count <= 1 {
                parts.hour = rule.hours[0]
                parts.minute = rule.minutes.first ?? 0
            } else {
                parts.hour = 9
            }
        }
        parts.minute = parts.minute ?? 0
        parts.second = parts.second ?? 0

        if parts.year != nil, parts.month != nil, parts.day != nil, let date = calendar.date(from: parts) {
            return date
        }
        // Counting from just before now, so a time a few seconds ago is now rather than tomorrow.
        guard let date = calendar.nextDate(after: now.addingTimeInterval(-60), matching: parts, matchingPolicy: .nextTime) else {
            throw .invalidValue(parameter: "start time", value: "that date")
        }
        return date
    }

    // MARK: - Answers

    private static let nowPhrases: Set<String> = [
        "now", "right now", "today", "immediately", "right away", "straight away", "straightaway", "asap",
        "as soon as possible", "whenever", "anytime", "any time", "skip",
    ]
    private static let leadingFillers: Set<String> = ["start", "starting", "begin", "beginning", "from", "um", "uh"]

    /// Lowercased, without "a.m." dots, surrounding punctuation, filler or doubled spaces.
    static func normalized(_ answer: String) -> String {
        var text = answer.lowercased()
            .replacingOccurrences(of: "a.m.", with: "am")
            .replacingOccurrences(of: "p.m.", with: "pm")
            .replacingOccurrences(of: "o’clock", with: "o'clock")
        text = text.replacingOccurrences(of: #"([a-z])-([a-z])"#, with: "$1 $2", options: .regularExpression)
        var words = text
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        while let first = words.first, leadingFillers.contains(first) { words.removeFirst() }
        if words.last == "please" { words.removeLast() }
        return words.joined(separator: " ")
    }

    // MARK: Delays

    private static let unitSeconds: [String: TimeInterval] = [
        "second": 1, "seconds": 1, "sec": 1, "secs": 1,
        "minute": 60, "minutes": 60, "min": 60, "mins": 60,
        "hour": 3_600, "hours": 3_600, "hr": 3_600, "hrs": 3_600,
        "day": 86_400, "days": 86_400,
        "week": 604_800, "weeks": 604_800,
    ]

    /// "in 20 minutes", "in an hour and a half", "in 1h30m".
    static func delay(_ text: String) -> TimeInterval? {
        guard text.hasPrefix("in ") else { return nil }
        var rest = String(text.dropFirst(3))
        for (phrase, replacement) in [
            ("an hour and a half", "90 minutes"),
            ("a quarter of an hour", "15 minutes"),
            ("quarter of an hour", "15 minutes"),
            ("half an hour", "30 minutes"),
            ("half hour", "30 minutes"),
            ("a couple of", "2"),
            ("a couple", "2"),
            ("a few", "3"),
        ] {
            rest = rest.replacingOccurrences(of: phrase, with: replacement)
        }
        if let compact = try? NagLink.duration(rest) { return compact }

        var total: TimeInterval = 0
        var amount: Double?
        var matched = false
        for word in rest.split(separator: " ").map(String.init) where word != "and" {
            if let unit = unitSeconds[word] {
                guard let count = amount else { return nil }
                total += count * unit
                amount = nil
                matched = true
            } else if let number = quantity(word) {
                // "twenty five" is one number.
                if let tens = amount, tens >= 20, tens.truncatingRemainder(dividingBy: 10) == 0, number < 10 {
                    amount = tens + number
                } else {
                    guard amount == nil else { return nil }
                    amount = number
                }
            } else {
                return nil
            }
        }
        return matched && amount == nil ? total : nil
    }

    /// "20", "1.5", "twenty", "a" or "an".
    private static func quantity(_ word: String) -> Double? {
        if word.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) { return Double(word) }
        if word == "a" || word == "an" { return 1 }
        return wordNumbers[word].map(Double.init)
    }

    // MARK: Clock times

    private enum Meridiem { case am, pm }

    private static let wordNumbers: [String: Int] = {
        let ones = [
            "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
            "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
        ]
        var numbers = Dictionary(uniqueKeysWithValues: ones.enumerated().map { ($0.element, $0.offset) })
        for (index, tens) in ["twenty", "thirty", "forty", "fifty"].enumerated() {
            numbers[tens] = (index + 2) * 10
        }
        numbers["oh"] = 0
        return numbers
    }()

    private enum Day: Equatable {
        case tomorrow
        /// A calendar weekday number, 1 for Sunday.
        case weekday(Int)
    }

    private static let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// A clock time with an optional day: "8", "at 8:30", "8 PM", "noon", "tonight at 8", "tomorrow at 9",
    /// "Friday at 5". A day alone is 9 AM. Other answers without a clock time are left to date detection.
    private static func dayAndTime(_ text: String, now: Date, calendar: Calendar) -> Date? {
        var day: Day?
        var hint: Meridiem?
        var night = false
        var words: [String] = []
        for word in text.split(separator: " ").map(String.init) {
            if word == "tomorrow" {
                day = .tomorrow
            } else if let index = weekdayNames.firstIndex(of: word) {
                day = .weekday(index + 1)
            } else {
                switch word {
                case "today", "this", "next", "on", "at", "around", "about", "by", "in", "the": break
                case "tonight", "night":
                    hint = .pm
                    night = true
                case "evening", "afternoon": hint = .pm
                case "morning": hint = .am
                default: words.append(word)
                }
            }
        }

        let minutes: [Int]
        if words.isEmpty {
            guard day != nil, hint != .pm else { return nil }
            minutes = [9 * 60]
        } else {
            guard let clock = clockMinutes(words, hint: hint, night: night, laterDay: day != nil) else { return nil }
            minutes = clock
        }

        // Counting from just before now, so "now-ish" isn't tomorrow.
        let after = now.addingTimeInterval(-60)
        switch day {
        case .tomorrow?:
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return nil }
            return minutes
                .compactMap { calendar.date(bySettingHour: $0 / 60, minute: $0 % 60, second: 0, of: tomorrow) }
                .min()
        case .weekday(let weekday)?:
            return minutes
                .compactMap { NagTime(minute: $0, weekdays: [weekday]).occurrence(after: after, calendar: calendar) }
                .min()
        case nil:
            return minutes
                .compactMap { NagTime(minute: $0, weekdays: Set(1...7)).occurrence(after: after, calendar: calendar) }
                .min()
        }
    }

    /// The minutes after midnight `words` could mean: one time when it's clear, or the AM and PM times for
    /// "8" alone. On a `laterDay` an hour alone is in waking hours: 7 to 11 is morning, 12 to 6 afternoon.
    /// At `night`, 12 is midnight.
    private static func clockMinutes(_ words: [String], hint: Meridiem?, night: Bool, laterDay: Bool) -> [Int]? {
        var words = words
        var meridiem: Meridiem?
        // "8pm" and "8:30am" arrive as one word.
        if let last = words.last {
            for (suffix, value) in [("am", Meridiem.am), ("pm", .pm)] where last.hasSuffix(suffix) {
                let stem = String(last.dropLast(suffix.count))
                words.removeLast()
                if !stem.isEmpty { words.append(stem) }
                meridiem = value
            }
        }
        if ["o'clock", "oclock"].contains(words.last) { words.removeLast() }

        switch words {
        case ["noon"], ["midday"]: return [12 * 60]
        case ["midnight"]: return [0]
        default: break
        }

        let hour: Int
        var minute = 0
        if words.count == 1, let first = words.first, first.contains(":") {
            let pieces = first.split(separator: ":", omittingEmptySubsequences: false)
            guard pieces.count == 2, let h = Int(pieces[0]), pieces[1].count == 2, let m = Int(pieces[1]) else { return nil }
            hour = h
            minute = m
        } else {
            // "8", "8 30", "eight", "eight thirty", "eight forty five", "eight oh five".
            let numbers = words.map { Int($0) ?? wordNumbers[$0] }
            guard !numbers.isEmpty, numbers.count <= 3, let first = numbers.first, let h = first else { return nil }
            hour = h
            let rest = numbers.dropFirst()
            guard rest.allSatisfy({ $0 != nil }) else { return nil }
            minute = rest.compactMap { $0 }.reduce(0, +)
        }
        guard (0..<60).contains(minute) else { return nil }

        switch meridiem ?? hint {
        case .am?:
            guard (1...12).contains(hour) else { return nil }
            return [(hour % 12) * 60 + minute]
        case .pm?:
            guard (1...12).contains(hour) else { return nil }
            if night, meridiem == nil, hour == 12 { return [minute] }
            return [(hour % 12 + 12) * 60 + minute]
        case nil:
            guard (0..<24).contains(hour) else { return nil }
            guard (1...12).contains(hour) else { return [hour * 60 + minute] }
            if laterDay {
                return [((7...11).contains(hour) ? hour : hour % 12 + 12) * 60 + minute]
            }
            return [(hour % 12) * 60 + minute, (hour % 12 + 12) * 60 + minute]
        }
    }

    // MARK: Detection

    /// The first date the system finds in `text`, such as "Friday at 5 PM" or "next Monday".
    private static func detectedDate(_ text: String) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.firstMatch(in: text, range: range)?.date
    }
}
