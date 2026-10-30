import Foundation
import NagCore
import Testing
@testable import NagMCP

/// A temporary store, a fixed UTC calendar and a fixed clock: 2026-10-28 (a Wednesday) 10:00.
final class MCPFixture: @unchecked Sendable {
    let directory = FileManager.default.temporaryDirectory.appending(path: "nag-mcp-\(UUID().uuidString)")
    let store: SharedStore
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()
    private let lock = NSLock()
    private var _changes = 0
    var changes: Int { lock.withLock { _changes } }

    init() {
        store = SharedStore(directory: directory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func date(_ day: Int = 28, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    var now: Date { date(28, 10) }

    lazy var server: MCPServer = {
        let now = now
        let tools = NagTools(store: store, calendar: calendar, clock: { now }, onChange: { [weak self] in
            self?.lock.withLock { self?._changes += 1 }
        })
        return MCPServer(tools: tools, version: "test")
    }()

    /// Sends a request and returns the decoded response.
    @discardableResult
    func send(_ message: JSONValue, clientName: String? = "Claude") -> JSONValue? {
        server.handle(message.encoded(), clientName: clientName).body.flatMap(JSONValue.decode)
    }

    /// Calls a tool and returns its result.
    @discardableResult
    func call(_ tool: String, _ arguments: JSONValue = [:], clientName: String? = "Claude") -> JSONValue {
        let response = send(
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(tool), "arguments": arguments]],
            clientName: clientName
        )
        return response?["result"] ?? .null
    }
}

struct MCPProtocolTests {
    @Test func initializeNegotiatesTheVersionAndNamesTheClient() {
        let fixture = MCPFixture()
        let message: JSONValue = [
            "jsonrpc": "2.0", "id": "init",
            "method": "initialize",
            "params": ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "Cursor", "version": "1"]],
        ]
        let reply = fixture.server.handle(message.encoded(), clientName: nil)
        #expect(reply.initialization == MCPServer.Initialization(clientName: "Cursor"))
        let response = reply.body.flatMap(JSONValue.decode)
        #expect(response?["id"] == "init")
        #expect(response?["result"]?["protocolVersion"] == "2025-03-26")
        #expect(response?["result"]?["capabilities"]?["tools"] != nil)
        #expect(response?["result"]?["serverInfo"]?["name"] == "nag")
        #expect(response?["result"]?["instructions"]?.stringValue?.contains("2026-10-28T10:00:00Z") == true)
    }

    @Test func unknownVersionGetsTheNewest() {
        let fixture = MCPFixture()
        let response = fixture.send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "1999-01-01"]])
        #expect(response?["result"]?["protocolVersion"] == .string(MCPServer.supportedProtocolVersions[0]))
    }

    @Test func notificationsAndResponsesGetNoReply() {
        let fixture = MCPFixture()
        #expect(fixture.send(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
        #expect(fixture.send(["jsonrpc": "2.0", "id": 9, "result": [:]]) == nil)
    }

    @Test func pingAndToolList() {
        let fixture = MCPFixture()
        #expect(fixture.send(["jsonrpc": "2.0", "id": 1, "method": "ping"])?["result"] == [:])
        let tools = fixture.send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])?["result"]?["tools"]
        guard case .array(let list) = tools else {
            Issue.record("No tool list")
            return
        }
        #expect(list.compactMap { $0["name"]?.stringValue } == ["create_nag", "list_nags", "complete_nag", "snooze_nag"])
        #expect(list.allSatisfy { $0["inputSchema"]?["type"] == "object" })
    }

    @Test func errors() {
        let fixture = MCPFixture()
        #expect(fixture.send(["jsonrpc": "2.0", "id": 1, "method": "resources/list"])?["error"]?["code"] == -32601)
        #expect(fixture.send(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "nope"]])?["error"]?["code"] == -32602)
        let parseError = fixture.server.handle(Data("{not json".utf8), clientName: nil).body.flatMap(JSONValue.decode)
        #expect(parseError?["error"]?["code"] == -32700)
        #expect(parseError?["id"] == .null)
    }

    @Test func batchesAnswerOnlyRequests() {
        let fixture = MCPFixture()
        let response = fixture.send([
            ["jsonrpc": "2.0", "id": 1, "method": "ping"],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "ping"],
        ])
        guard case .array(let responses) = response else {
            Issue.record("Expected an array")
            return
        }
        #expect(responses.compactMap { $0["id"]?.intValue } == [1, 2])
    }
}

struct NagToolTests {
    @Test func createUsesTheClientAsSource() {
        let fixture = MCPFixture()
        let result = fixture.call("create_nag", ["title": "Call mum"])
        #expect(result["isError"] == false)
        #expect(result["structuredContent"]?["created"] == true)
        #expect(result["structuredContent"]?["nag"]?["status"] == "due")
        #expect(result["content"]?.prettyString().contains("Added") == true)

        let task = fixture.store.load().tasks.first
        #expect(task?.title == "Call mum")
        #expect(task?.source == "Claude")
        #expect(task?.startAt == fixture.now)
        #expect(fixture.changes == 1)
    }

    @Test func createWithoutAClientNameUsesTheFallback() {
        let fixture = MCPFixture()
        fixture.call("create_nag", ["title": "x"], clientName: nil)
        #expect(fixture.store.load().tasks.first?.source == NagTools.fallbackSource)
    }

    @Test func createTakesAllTheOptions() {
        let fixture = MCPFixture()
        let result = fixture.call("create_nag", [
            "title": "Pills",
            "notes": "With water",
            "times": ["09:00", "21:00"],
            "days": ["mon", "wed", "fri"],
            "interval_minutes": 5,
            "escalation": "relentless",
            "snooze_minutes": 15,
            "unlimited_snoozes": true,
            "break_through_focus": false,
            "source": "Gmail",
            "external_id": "msg-1",
            "link": "https://mail.google.com/x",
        ])
        #expect(result["isError"] == false)
        let task = fixture.store.load().tasks[0]
        #expect(task.repeatRule == .custom)
        #expect(task.times.map(\.minute) == [540, 1260])
        #expect(task.times.allSatisfy { $0.weekdays == [2, 4, 6] })
        // Wednesday 10:00 now, so the next time is 21:00 today.
        #expect(task.startAt == fixture.date(28, 21))
        #expect(task.style.intervalMinutes == 5)
        #expect(task.style.escalation == .relentless)
        #expect(task.style.snoozeMinutes == 15)
        #expect(task.style.maxSnoozes == nil)
        #expect(task.style.breakThroughFocus == false)
        #expect(task.source == "Gmail")
        #expect(task.externalID == "msg-1")
        #expect(task.link == URL(string: "https://mail.google.com/x"))
    }

    @Test func createAgainWithTheSameExternalIDUpdates() {
        let fixture = MCPFixture()
        fixture.call("create_nag", ["title": "Reply to Sam", "external_id": "thread-9", "start": "2026-10-29T09:00"])
        let result = fixture.call("create_nag", ["title": "Reply to Sam today", "external_id": "thread-9"])
        #expect(result["structuredContent"]?["created"] == false)
        let tasks = fixture.store.load().tasks
        #expect(tasks.count == 1)
        #expect(tasks[0].title == "Reply to Sam today")
        #expect(tasks[0].startAt == fixture.date(29, 9))
    }

    @Test func createErrorsAreToolErrors() {
        let fixture = MCPFixture()
        let result = fixture.call("create_nag", ["title": "x", "repeat": "hourly"])
        #expect(result["isError"] == true)
        #expect(result["content"]?.prettyString().contains("hourly") == true)
        #expect(fixture.call("create_nag", ["notes": "no title"])["isError"] == true)
        #expect(fixture.call("create_nag", ["title": ["nested": "object"]])["isError"] == true)
        #expect(fixture.store.load().tasks.isEmpty)
        #expect(fixture.changes == 0)
    }

    @Test func listFiltersByStatusAndSource() {
        let fixture = MCPFixture()
        fixture.store.update { state in
            state.tasks = [
                NagTask(title: "Due", startAt: fixture.date(28, 9), source: "Claude", now: fixture.date(28, 8)),
                NagTask(title: "Later", startAt: fixture.date(29, 9), now: fixture.date(28, 8)),
                {
                    var done = NagTask(title: "Done", startAt: fixture.date(28, 8), now: fixture.date(28, 8))
                    done.complete(at: fixture.date(28, 9), calendar: fixture.calendar)
                    return done
                }(),
            ]
        }
        func titles(_ arguments: JSONValue) -> [String] {
            guard case .array(let nags) = fixture.call("list_nags", arguments)["structuredContent"]?["nags"] else { return [] }
            return nags.compactMap { $0["title"]?.stringValue }
        }
        #expect(titles([:]) == ["Due", "Later"])
        #expect(titles(["status": "due"]) == ["Due"])
        #expect(titles(["status": "upcoming"]) == ["Later"])
        #expect(titles(["status": "done"]) == ["Done"])
        #expect(titles(["status": "all"]).count == 3)
        #expect(titles(["source": "Claude"]) == ["Due"])
        #expect(fixture.call("list_nags", ["status": "bogus"])["isError"] == true)
    }

    @Test func completeByIDOrExternalID() throws {
        let fixture = MCPFixture()
        let created = fixture.call("create_nag", ["title": "Bins", "external_id": "bins"])
        let id = try #require(created["structuredContent"]?["nag"]?["id"]?.stringValue)

        let done = fixture.call("complete_nag", ["id": .string(id)])
        #expect(done["isError"] == false)
        #expect(done["structuredContent"]?["nag"]?["status"] == "finished")
        #expect(fixture.store.load().tasks[0].isFinished)

        // Finishing it again explains why not.
        #expect(fixture.call("complete_nag", ["external_id": "bins"])["isError"] == true)
        #expect(fixture.call("complete_nag", ["id": "not-a-uuid"])["isError"] == true)
    }

    @Test func nagsNeedingAKeyScanCantBeCompleted() {
        let fixture = MCPFixture()
        let task = NagTask(title: "Pills", startAt: fixture.date(28, 9), proof: .scanKey(UUID()), now: fixture.date(28, 8))
        fixture.store.update { $0.tasks = [task] }
        let result = fixture.call("complete_nag", ["id": .string(task.id.uuidString)])
        #expect(result["isError"] == true)
        #expect(result["content"]?.prettyString().contains("iPhone") == true)
        #expect(!fixture.store.load().tasks[0].isFinished)
    }

    @Test func snoozeOnlyWhatsDue() {
        let fixture = MCPFixture()
        let due = NagTask(title: "Due", startAt: fixture.date(28, 9), now: fixture.date(28, 8))
        let later = NagTask(title: "Later", startAt: fixture.date(29, 9), now: fixture.date(28, 8))
        fixture.store.update { $0.tasks = [due, later] }

        let snoozed = fixture.call("snooze_nag", ["id": .string(due.id.uuidString)])
        #expect(snoozed["isError"] == false)
        #expect(snoozed["structuredContent"]?["nag"]?["status"] == "snoozed")
        #expect(fixture.store.load().tasks[0].snoozedUntil == fixture.date(28, 10, 10))

        #expect(fixture.call("snooze_nag", ["id": .string(later.id.uuidString)])["isError"] == true)
    }
}
