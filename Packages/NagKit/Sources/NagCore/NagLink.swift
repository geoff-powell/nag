import Foundation

/// `nag://add` links, so anything that can open a URL can hand Nag a nag: a link in Notes, a Calendar
/// event's URL field, a Muse card, a script, or an AI assistant.
///
///     nag://add?title=Take%20pills&at=2026-10-30T09:00&repeat=daily&source=Muse&id=card-42
///
/// Parameters (only `title` is required):
/// - `title` (or `text`), `notes`
/// - `at`: ISO 8601 (`2026-10-30T09:00:00Z`), a local date and time (`2026-10-30T09:00`), a date (9 AM
///   that day) or a time (`17:30`, the next time it comes round)
/// - `in`: start after a delay, such as `30m`, `2h` or `1h30m`. Ignored when `at` is given.
/// - `repeat`: `once`, `daily`, `weekdays`, `weekly` or `custom`
/// - `times`: comma-separated 24-hour times for a custom schedule, such as `09:00,21:00`
/// - `days`: for those times, such as `mon,wed,fri`, `weekdays`, `weekends` or `daily`. Defaults to every day.
/// - `every`: minutes between nags. `escalation`: `steady`, `gentle` or `relentless`.
/// - `snooze`: snooze length in minutes. `snoozes`: a number, or `unlimited`.
/// - `focus`: `true` or `false`, whether nags break through Focus
/// - `source`, `id`: who sent it and their ID for it. The same pair again updates the nag.
/// - `link`: a URL that opens the original item
extension NagRequest {
    public static let urlScheme = "nag"

    /// Whether `url` is a Nag link, even one this version can't read.
    public static func isNagURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == urlScheme
    }

    public init(url: URL, now: Date, calendar: Calendar) throws(NagRequestError) {
        guard Self.isNagURL(url), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw .unsupportedURL
        }
        let action = (components.host ?? components.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        guard action == "add" || action == "new" else { throw .unsupportedURL }

        var query: [String: String] = [:]
        for item in components.percentEncodedQueryItems ?? [] {
            // Forms encode spaces as "+", so a literal plus arrives as %2B.
            let value = item.value?.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            query[item.name.lowercased()] = value
        }
        func value(_ names: String...) -> String? {
            names.lazy.compactMap { query[$0].nonBlank }.first
        }

        self.init(title: value("title", "text", "name") ?? "")
        notes = query["notes"]
        source = value("source")
        externalID = value("id", "externalid", "external_id")

        if let at = value("at", "start", "date") {
            startAt = try NagLink.date(at, now: now, calendar: calendar)
        } else if let delay = value("in") {
            startAt = now.addingTimeInterval(try NagLink.duration(delay))
        }

        if let rule = value("repeat") {
            repeatRule = try NagLink.repeatRule(rule)
        }
        let days = try value("days").map(NagLink.weekdays) ?? Set(1...7)
        if let times = value("times", "time") {
            self.times = try NagLink.minutes(times).map { NagTime(minute: $0, weekdays: days) }
        } else if value("days") != nil {
            // Days alone repeat at the start's time of day.
            let start = startAt ?? now
            let parts = calendar.dateComponents([.hour, .minute], from: start)
            self.times = [NagTime(minute: (parts.hour ?? 9) * 60 + (parts.minute ?? 0), weekdays: days)]
        }

        if let every = value("every", "interval") {
            intervalMinutes = try NagLink.int(every, parameter: "nag interval")
        }
        if let raw = value("escalation") {
            guard let escalation = Escalation(rawValue: raw.lowercased()) else {
                throw .invalidValue(parameter: "escalation", value: raw)
            }
            self.escalation = escalation
        }
        if let snooze = value("snooze") {
            snoozeMinutes = try NagLink.int(snooze, parameter: "snooze length")
        }
        if let snoozes = value("snoozes") {
            snoozeLimit = ["unlimited", "none", "any"].contains(snoozes.lowercased())
                ? .unlimited
                : .limited(try NagLink.int(snoozes, parameter: "snooze limit"))
        }
        if let focus = value("focus") {
            breakThroughFocus = try NagLink.bool(focus, parameter: "focus")
        }
        if let raw = value("link", "url") {
            guard let link = URL(string: raw), link.scheme != nil else {
                throw .invalidValue(parameter: "link", value: raw)
            }
            self.link = link
        }
        try validateRanges()
    }
}

/// Parsers for `nag://add` parameter values.
enum NagLink {
    static func date(_ raw: String, now: Date, calendar: Calendar) throws(NagRequestError) -> Date {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        formatter.dateFormat = "yyyy-MM-dd"
        if let day = formatter.date(from: raw),
           let date = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) {
            return date
        }
        if let minute = try? minuteOfDay(raw) {
            let time = NagTime(minute: minute, weekdays: Set(1...7))
            // The next time it comes round, counting from just before now so "now-ish" isn't tomorrow.
            if let date = time.occurrence(after: now.addingTimeInterval(-60), calendar: calendar) { return date }
        }
        throw .invalidValue(parameter: "start", value: raw)
    }

    /// "30m", "2h", "1h30m", "1d". A bare number is minutes.
    static func duration(_ raw: String) throws(NagRequestError) -> TimeInterval {
        let text = raw.lowercased().filter { !$0.isWhitespace }
        if let minutes = Int(text), minutes >= 0 { return TimeInterval(minutes * 60) }

        var total: TimeInterval = 0
        var number = ""
        var matchedAny = false
        for character in text {
            if character.isNumber {
                number.append(character)
                continue
            }
            guard let amount = Int(number) else { throw .invalidValue(parameter: "delay", value: raw) }
            switch character {
            case "s": total += TimeInterval(amount)
            case "m": total += TimeInterval(amount * 60)
            case "h": total += TimeInterval(amount * 3600)
            case "d": total += TimeInterval(amount * 86_400)
            default: throw .invalidValue(parameter: "delay", value: raw)
            }
            number = ""
            matchedAny = true
        }
        guard matchedAny, number.isEmpty else { throw .invalidValue(parameter: "delay", value: raw) }
        return total
    }

    static func repeatRule(_ raw: String) throws(NagRequestError) -> RepeatRule {
        switch raw.lowercased() {
        case "once", "never", "none": .never
        case "daily", "day", "everyday": .daily
        case "weekdays", "weekday": .weekdays
        case "weekly", "week": .weekly
        case "custom": .custom
        default: throw .invalidValue(parameter: "repeat", value: raw)
        }
    }

    /// "mon,wed,fri", "weekdays", "weekends", "daily". Calendar weekday numbers, 1 = Sunday.
    static func weekdays(_ raw: String) throws(NagRequestError) -> Set<Int> {
        let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        var days = Set<Int>()
        for part in raw.lowercased().split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "daily", "everyday", "all": days.formUnion(1...7)
            case "weekdays": days.formUnion(2...6)
            case "weekends": days.formUnion([1, 7])
            default:
                guard part.count >= 3, let index = names.firstIndex(of: String(part.prefix(3))) else {
                    throw .invalidValue(parameter: "days", value: raw)
                }
                days.insert(index + 1)
            }
        }
        guard !days.isEmpty else { throw .invalidValue(parameter: "days", value: raw) }
        return days
    }

    /// "09:00,21:30" as minutes after midnight.
    static func minutes(_ raw: String) throws(NagRequestError) -> [Int] {
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { throw .invalidValue(parameter: "times", value: raw) }
        var result: [Int] = []
        for part in parts {
            result.append(try minuteOfDay(part))
        }
        return result
    }

    /// "9:00", "17:30" or "0930".
    static func minuteOfDay(_ raw: String) throws(NagRequestError) -> Int {
        let pieces = raw.split(separator: ":")
        let hour: Int?
        let minute: Int?
        if pieces.count == 2 {
            hour = Int(pieces[0])
            minute = Int(pieces[1])
        } else if raw.count == 4, let value = Int(raw) {
            hour = value / 100
            minute = value % 100
        } else {
            hour = nil
            minute = nil
        }
        guard let hour, let minute, (0..<24).contains(hour), (0..<60).contains(minute) else {
            throw .invalidValue(parameter: "time", value: raw)
        }
        return hour * 60 + minute
    }

    static func int(_ raw: String, parameter: String) throws(NagRequestError) -> Int {
        guard let value = Int(raw) else { throw .invalidValue(parameter: parameter, value: raw) }
        return value
    }

    static func bool(_ raw: String, parameter: String) throws(NagRequestError) -> Bool {
        switch raw.lowercased() {
        case "true", "yes", "1", "on": true
        case "false", "no", "0", "off": false
        default: throw .invalidValue(parameter: parameter, value: raw)
        }
    }
}
