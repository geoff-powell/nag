import Foundation
import NagCore

/// Nag's MCP tools. They work straight on the shared store, so they behave the same whether they run in
/// the Mac app (HTTP) or in a separate `--mcp` process (stdio); the app picks up changes either way.
public struct NagTools: Sendable {
    let store: SharedStore
    let calendar: Calendar
    let clock: @Sendable () -> Date
    let onChange: @Sendable () -> Void

    /// - Parameter onChange: Called after a tool changes the stored state.
    public init(
        store: SharedStore,
        calendar: Calendar = .current,
        clock: @escaping @Sendable () -> Date = { Date() },
        onChange: @escaping @Sendable () -> Void = {}
    ) {
        self.store = store
        self.calendar = calendar
        self.clock = clock
        self.onChange = onChange
    }

    /// The source for nags from a client that doesn't say which source it is.
    static let fallbackSource = "MCP"

    /// Sent to the client on `initialize`, for the model's context.
    public func instructions() -> String {
        """
        Nag reminds the user about each nag, again and again, until it's marked done. Use create_nag for \
        things the user mustn't forget. Pass external_id (the ID of the email, event or task the nag comes \
        from) so that calling create_nag again updates that nag instead of adding a duplicate. Times \
        without a time zone are the user's local time. The user's time zone is \
        \(calendar.timeZone.identifier), and it's now \(Self.timestamp(clock(), calendar: calendar)).
        """
    }

    // MARK: - Definitions

    public var definitions: [JSONValue] {
        [
            [
                "name": "create_nag",
                "title": "Create nag",
                "description": """
                    Adds a nag that keeps reminding the user until it's done. If a nag from the same source \
                    and external_id exists, updates it instead; fields left out keep their values.
                    """,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "What needs doing."],
                        "notes": ["type": "string", "description": "Extra detail, or the first tiny step."],
                        "start": [
                            "type": "string",
                            "description": """
                                When nagging starts: ISO 8601 with or without a time zone (2026-10-30T09:00), \
                                a date (9 AM that day), or a 24-hour time (17:30, the next time it comes round). \
                                Leave out to start now.
                                """,
                        ],
                        "start_in": ["type": "string", "description": "Start after a delay instead, such as 30m, 2h or 1h30m."],
                        "repeat": [
                            "type": "string",
                            "enum": ["once", "daily", "weekdays", "weekly", "custom"],
                            "description": "Defaults to once, or custom when times are given.",
                        ],
                        "times": [
                            "type": "array",
                            "items": ["type": "string", "pattern": "^[0-9]{1,2}:[0-9]{2}$"],
                            "description": "24-hour times for a custom schedule, such as [\"09:00\", \"21:00\"].",
                        ],
                        "days": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Days for those times: mon, tue, wed, thu, fri, sat, sun, weekdays, weekends or daily. Defaults to every day.",
                        ],
                        "interval_minutes": ["type": "integer", "minimum": 1, "maximum": 1440, "description": "Minutes between nags. Default 15."],
                        "escalation": [
                            "type": "string",
                            "enum": ["steady", "gentle", "relentless"],
                            "description": "How nagging speeds up while it's overdue. Default gentle.",
                        ],
                        "snooze_minutes": ["type": "integer", "minimum": 1, "maximum": 1440, "description": "Snooze length. Default 10."],
                        "max_snoozes": ["type": "integer", "minimum": 0, "description": "Snoozes allowed each time it comes due. Default 3."],
                        "unlimited_snoozes": ["type": "boolean", "description": "Allow any number of snoozes."],
                        "break_through_focus": ["type": "boolean", "description": "Deliver nags through Focus. Default true."],
                        "source": ["type": "string", "description": "Where this came from, shown on the nag. Defaults to the client's name."],
                        "external_id": ["type": "string", "description": "The source's ID for the item, so calling again updates the same nag."],
                        "link": ["type": "string", "format": "uri", "description": "A URL that opens the original item."],
                    ],
                    "required": ["title"],
                ],
                "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
            ],
            [
                "name": "list_nags",
                "title": "List nags",
                "description": "Lists the user's nags with their status: due, snoozed, upcoming, done_today or finished.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "status": [
                            "type": "string",
                            "enum": ["open", "due", "upcoming", "done", "all"],
                            "description": "open (default) is everything not finished: due, snoozed and upcoming. done is finished or done today.",
                        ],
                        "source": ["type": "string", "description": "Only nags from this source."],
                    ],
                ],
                "annotations": ["readOnlyHint": true, "openWorldHint": false],
            ],
            [
                "name": "complete_nag",
                "title": "Complete nag",
                "description": """
                    Marks a nag done. Repeating nags move on to their next time. Nags that need a key scanned \
                    on the user's iPhone can't be completed here.
                    """,
                "inputSchema": Self.lookupSchema,
                "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
            ],
            [
                "name": "snooze_nag",
                "title": "Snooze nag",
                "description": "Snoozes a due nag for its snooze length, if it has snoozes left.",
                "inputSchema": Self.lookupSchema,
                "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
            ],
        ]
    }

    private static let lookupSchema: JSONValue = [
        "type": "object",
        "properties": [
            "id": ["type": "string", "description": "The nag's id, from create_nag or list_nags."],
            "external_id": ["type": "string", "description": "Or the external_id it was created with."],
            "source": ["type": "string", "description": "With external_id: the source it was created with. Defaults to the client's name."],
        ],
    ]

    // MARK: - Calls

    /// The tool's result, or `nil` for an unknown tool.
    public func call(_ name: String, arguments: [String: JSONValue], clientName: String?) -> JSONValue? {
        switch name {
        case "create_nag": create(arguments, clientName: clientName)
        case "list_nags": list(arguments)
        case "complete_nag": complete(arguments, clientName: clientName)
        case "snooze_nag": snooze(arguments, clientName: clientName)
        default: nil
        }
    }

    /// MCP argument names, and the `nag://add` parameter each one maps to.
    private static let createParameters = [
        "title": "title", "notes": "notes", "start": "at", "start_in": "in", "repeat": "repeat",
        "times": "times", "days": "days", "interval_minutes": "every", "escalation": "escalation",
        "snooze_minutes": "snooze", "max_snoozes": "snoozes", "break_through_focus": "focus",
        "source": "source", "external_id": "id", "link": "link",
    ]

    private func create(_ arguments: [String: JSONValue], clientName: String?) -> JSONValue {
        var parameters: [String: String] = [:]
        for (name, value) in arguments where !value.isNull {
            guard let parameter = Self.createParameters[name] else { continue }
            guard let text = Self.text(value) else { return Self.failure("“\(name)” has the wrong type.") }
            parameters[parameter] = text
        }
        if arguments["unlimited_snoozes"]?.boolValue == true { parameters["snoozes"] = "unlimited" }
        parameters["source"] = Self.source(parameters["source"], clientName: clientName)

        let now = clock()
        let draft: NagDraft
        do {
            let request = try NagRequest(parameters: parameters, now: now, calendar: calendar)
            let outcome: Result<NagDraft, NagRequestError> = store.update { state in
                Result { () throws(NagRequestError) in try state.apply(request, now: now, calendar: calendar) }
            }
            draft = try outcome.get()
        } catch {
            return Self.failure(error.localizedDescription)
        }
        onChange()

        let task = draft.task
        let start = task.startAt <= now.addingTimeInterval(60)
            ? "nagging now"
            : "starting \(Self.timestamp(task.startAt, calendar: calendar))"
        let summary = "\(draft.isNew ? "Added" : "Updated") “\(task.title)”, \(start)."
        let nag = describe(task, now: now)
        return Self.success("\(summary)\n\(nag.prettyString())", structured: ["created": .bool(draft.isNew), "nag": nag])
    }

    private func list(_ arguments: [String: JSONValue]) -> JSONValue {
        let filter = arguments["status"]?.stringValue ?? "open"
        let wanted: Set<String>
        switch filter {
        case "open": wanted = ["due", "snoozed", "upcoming"]
        case "due": wanted = ["due", "snoozed"]
        case "upcoming": wanted = ["upcoming"]
        case "done": wanted = ["done_today", "finished"]
        case "all": wanted = ["due", "snoozed", "upcoming", "done_today", "finished"]
        default: return Self.failure("“\(filter)” isn't a status. Use open, due, upcoming, done or all.")
        }
        let source = arguments["source"]?.stringValue

        let now = clock()
        let nags = store.load().tasks
            .filter { wanted.contains(status(of: $0, now: now)) }
            .filter { source == nil || $0.source == source }
            .sorted { $0.startAt < $1.startAt }
            .map { describe($0, now: now) }
        let result: JSONValue = ["now": .string(Self.timestamp(now, calendar: calendar)), "count": .int(nags.count), "nags": .array(nags)]
        return Self.success(result.prettyString(), structured: result)
    }

    private func complete(_ arguments: [String: JSONValue], clientName: String?) -> JSONValue {
        let now = clock()
        return mutate(arguments, clientName: clientName) { task in
            if task.proof.keyID != nil {
                return "“\(task.title)” needs its key scanned on the user's iPhone to finish."
            }
            guard task.canComplete(at: now, calendar: calendar) else {
                return task.isFinished
                    ? "“\(task.title)” is already done."
                    : "“\(task.title)” is already done for today. It comes back \(Self.timestamp(task.startAt, calendar: calendar))."
            }
            task.complete(at: now, calendar: calendar)
            return nil
        } summary: { task in
            task.isRepeating
                ? "Done. “\(task.title)” comes back \(Self.timestamp(task.startAt, calendar: calendar))."
                : "Done. “\(task.title)” is finished."
        }
    }

    private func snooze(_ arguments: [String: JSONValue], clientName: String?) -> JSONValue {
        let now = clock()
        return mutate(arguments, clientName: clientName) { task in
            guard task.isOutstanding(at: now) else { return "“\(task.title)” isn't due, so there's nothing to snooze." }
            guard task.snooze(at: now) else { return "“\(task.title)” has no snoozes left." }
            return nil
        } summary: { task in
            "Snoozed “\(task.title)” until \(Self.timestamp(task.snoozedUntil ?? now, calendar: calendar))."
        }
    }

    /// Finds the nag the arguments point to and changes it. `change` returns a message when it can't.
    private func mutate(
        _ arguments: [String: JSONValue],
        clientName: String?,
        _ change: (inout NagTask) -> String?,
        summary: (NagTask) -> String
    ) -> JSONValue {
        let outcome: Result<NagTask, ToolFailure> = store.update { state in
            guard let index = self.index(of: arguments, in: state, clientName: clientName) else {
                return .failure(ToolFailure(message: "No nag matches. Use list_nags to find its id."))
            }
            var task = state.tasks[index]
            if let message = change(&task) { return .failure(ToolFailure(message: message)) }
            state.tasks[index] = task
            return .success(task)
        }
        switch outcome {
        case .success(let task):
            onChange()
            let nag = describe(task, now: clock())
            return Self.success("\(summary(task))\n\(nag.prettyString())", structured: ["nag": nag])
        case .failure(let failure):
            return Self.failure(failure.message)
        }
    }

    private func index(of arguments: [String: JSONValue], in state: NagState, clientName: String?) -> Int? {
        if let raw = arguments["id"]?.stringValue {
            guard let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)) else { return nil }
            return state.tasks.firstIndex { $0.id == id }
        }
        guard let externalID = arguments["external_id"]?.stringValue else { return nil }
        let source = Self.source(arguments["source"]?.stringValue, clientName: clientName)
        return state.tasks.firstIndex { $0.externalID == externalID && $0.source == source }
    }

    // MARK: - Output

    func status(of task: NagTask, now: Date) -> String {
        if task.isFinished { return "finished" }
        if task.isOutstanding(at: now) { return task.isSnoozed(at: now) ? "snoozed" : "due" }
        if let done = task.lastCompletedAt, calendar.isDate(done, inSameDayAs: now) { return "done_today" }
        return "upcoming"
    }

    func describe(_ task: NagTask, now: Date) -> JSONValue {
        var nag: [String: JSONValue] = [
            "id": .string(task.id.uuidString),
            "title": .string(task.title),
            "status": .string(status(of: task, now: now)),
            "starts_at": .string(Self.timestamp(task.startAt, calendar: calendar)),
            "repeat": .string(task.repeatRule == .never ? "once" : task.repeatRule.rawValue),
            "interval_minutes": .int(task.style.intervalMinutes),
            "needs_key_scan": .bool(task.proof.keyID != nil),
        ]
        if !task.notes.isEmpty { nag["notes"] = .string(task.notes) }
        if task.repeatRule == .custom { nag["schedule"] = .string(task.repeatLabel) }
        if let left = task.snoozesLeft { nag["snoozes_left"] = .int(left) }
        if task.isSnoozed(at: now), let until = task.snoozedUntil { nag["snoozed_until"] = .string(Self.timestamp(until, calendar: calendar)) }
        if let done = task.completedAt { nag["completed_at"] = .string(Self.timestamp(done, calendar: calendar)) }
        if let done = task.lastCompletedAt { nag["last_completed_at"] = .string(Self.timestamp(done, calendar: calendar)) }
        if let source = task.source { nag["source"] = .string(source) }
        if let externalID = task.externalID { nag["external_id"] = .string(externalID) }
        if let link = task.link { nag["link"] = .string(link.absoluteString) }
        return .object(nag)
    }

    static func timestamp(_ date: Date, calendar: Calendar) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func success(_ text: String, structured: JSONValue) -> JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "structuredContent": structured, "isError": false]
    }

    static func failure(_ message: String) -> JSONValue {
        ["content": [["type": "text", "text": .string(message)]], "isError": true]
    }

    static func source(_ given: String?, clientName: String?) -> String {
        for candidate in [given, clientName] {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty { return trimmed }
        }
        return fallbackSource
    }

    /// A scalar, or a list of scalars joined with commas, as `nag://add` parameters expect.
    static func text(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text): return text
        case .int(let number): return String(number)
        case .double(let number): return Int(exactly: number).map(String.init) ?? String(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .array(let items):
            let parts = items.map(text)
            guard !parts.contains(nil) else { return nil }
            return parts.compactMap { $0 }.joined(separator: ",")
        case .null, .object: return nil
        }
    }
}

struct ToolFailure: Error {
    let message: String
}
