import XCTest

/// End-to-end checks of the Mac menu bar app against a seeded store (see `MacUITesting` in the app).
///
/// Besides checking each surface appears, every test checks Nag settles down afterwards: a SwiftUI
/// update loop once kept the main thread busy at launch, using 100% CPU and gigabytes of memory, and
/// the menu bar icon never appeared.
///
/// Seeded nags:
/// - "Take meds": daily, 20 minutes overdue (so the nag panel shows too).
/// - "Water the plants": one-off, starts in 2 hours.
/// - "File taxes": one-off, finished.
@MainActor
final class NagMacUITests: XCTestCase {
    /// An idle menu bar app should be well under this. The runaway loop passed 3 GB in 20 seconds.
    static let maxFootprintMB = 500.0
    /// Average share of one core while nobody's touching the app.
    static let maxIdleCPU = 0.5
    static let idleWindow: TimeInterval = 5
    /// How long the main thread may go without running a 100 ms timer.
    static let maxMainThreadLag: TimeInterval = 2

    private var app: XCUIApplication!
    /// The app writes reports on itself here (see `MacUITesting`). The test runner is sandboxed, so it
    /// can't inspect another process directly.
    private let usageReportURL = FileManager.default.temporaryDirectory
        .appending(path: "NagUsage-\(UUID().uuidString).json")

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: usageReportURL)
    }

    func testLaunchSettlesWithoutRunawayCPUOrMemory() throws {
        launch()
        try assertSettles("after launch")
    }

    func testMenuBarExtraShowsDueNags() throws {
        launch()
        openMenuBarExtra()
        XCTAssertTrue(app.staticTexts["Take meds"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Water the plants"].firstMatch.exists)
        try assertSettles("with the menu bar extra open")
    }

    func testQuickAddFromMenuBarExtra() throws {
        launch(scenario: "empty")
        openMenuBarExtra()
        XCTAssertTrue(app.staticTexts["Nothing due. Nice."].firstMatch.waitForExistence(timeout: 5))
        let field = app.textFields["Add a nag and press Return"].firstMatch
        field.click()
        field.typeText("Buy milk\r")
        XCTAssertTrue(app.staticTexts["Buy milk"].firstMatch.waitForExistence(timeout: 5))
        try assertSettles("after adding a nag")
    }

    func testMainWindowListsNags() throws {
        launch()
        openMainWindow()
        XCTAssertTrue(app.staticTexts["Take meds"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Water the plants"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["File taxes"].firstMatch.exists)
        try assertSettles("with the main window open")
    }

    func testNewNagEditorSavesANag() throws {
        launch()
        openMainWindow()
        app.toolbars.buttons["New nag"].firstMatch.click()
        // The title is the editor's first field. Form rows don't expose their prompts as labels.
        let title = app.sheets.firstMatch.textFields.firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        try assertSettles("with the nag editor open")

        title.click()
        title.typeText("Call the dentist")
        app.buttons["Save"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Call the dentist"].firstMatch.waitForExistence(timeout: 5))
    }

    func testEachSectionOpens() throws {
        launch()
        openMainWindow()
        for section in ["Locks", "Settings", "Nags"] {
            let row = app.outlines.staticTexts[section].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), section)
            row.click()
            try assertSettles("on \(section)")
        }
    }

    // MARK: - Helpers

    private func launch(scenario: String = "sample") {
        app = XCUIApplication()
        app.launchArguments = ["-NagUITesting"]
        app.launchEnvironment["NAG_UI_SCENARIO"] = scenario
        app.launchEnvironment["NAG_UI_USAGE_REPORT"] = usageReportURL.path
        // `launch()` waits for the app to go idle, so a busy main thread already fails here.
        app.launch()
        XCTAssertTrue(statusItem.waitForExistence(timeout: 10), "The menu bar icon never appeared")
    }

    private var statusItem: XCUIElement {
        app.statusItems.firstMatch
    }

    /// Clicks the menu bar icon until its window shows. A click that lands while the status item is
    /// still settling in after launch can be dropped.
    private func openMenuBarExtra() {
        let field = app.textFields["Add a nag and press Return"].firstMatch
        for _ in 0..<3 {
            statusItem.click()
            if field.waitForExistence(timeout: 3) { return }
        }
        XCTFail("The menu bar extra didn't open")
    }

    /// Opens the main window from the menu bar extra, then closes the extra so it doesn't keep focus.
    private func openMainWindow() {
        openMenuBarExtra()
        app.buttons["Open Nag"].firstMatch.click()
        let window = app.windows["Nag"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "The main window didn't open")
        let field = app.textFields["Add a nag and press Return"].firstMatch
        if field.exists {
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(waitForDisappearance(field), "The menu bar extra didn't close")
        }
        window.click()
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    /// Leaves the app alone for a few seconds, then checks it isn't spinning, growing or stuck.
    private func assertSettles(_ context: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let start = try XCTUnwrap(latestUsage(), "Nag isn't reporting its usage", file: file, line: line)
        Thread.sleep(forTimeInterval: Self.idleWindow)
        let end = try XCTUnwrap(latestUsage(after: start), "Nag stopped reporting its usage \(context)", file: file, line: line)

        let cpu = (end.cpuSeconds - start.cpuSeconds) / (end.uptime - start.uptime)
        let footprintMB = end.footprintBytes / 1_048_576
        let summary = String(
            format: "%@: %.0f%% CPU, %.0f MB, main thread lag %.1fs",
            context, cpu * 100, footprintMB, end.mainThreadLag
        )
        XCTContext.runActivity(named: summary) { _ in }
        XCTAssertLessThan(cpu, Self.maxIdleCPU, "Nag kept the CPU busy \(summary)", file: file, line: line)
        XCTAssertLessThan(footprintMB, Self.maxFootprintMB, "Nag used too much memory \(summary)", file: file, line: line)
        XCTAssertLessThan(end.mainThreadLag, Self.maxMainThreadLag, "Nag's main thread is stuck \(summary)", file: file, line: line)
    }

    /// The newest report from the app, waiting briefly for one newer than `earlier`.
    private func latestUsage(after earlier: UsageReport? = nil, timeout: TimeInterval = 3) -> UsageReport? {
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            if let data = try? Data(contentsOf: usageReportURL),
               let report = try? JSONDecoder().decode(UsageReport.self, from: data),
               report.uptime > (earlier?.uptime ?? 0) {
                return report
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date.now < deadline
        return nil
    }
}

/// What `MacUITesting` in the app writes about itself every half second.
private struct UsageReport: Decodable {
    let cpuSeconds: Double
    let footprintBytes: Double
    let uptime: Double
    let mainThreadLag: Double
}
