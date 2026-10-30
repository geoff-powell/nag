import XCTest

/// End-to-end checks of the nag list: creating, editing, completing, snoozing, reopening,
/// duplicating and deleting nags, against a seeded store (see `UITesting` in the app).
///
/// Seeded nags:
/// - "Take meds": daily, 20 minutes overdue, 3 snoozes.
/// - "Water the plants": one-off, starts in 2 hours.
/// - "Stretch": daily, done earlier today.
/// - "File taxes": one-off, finished.
///
/// Set `NAG_UI_PAUSE` (seconds) to hold after each step, for screen recordings. From the command line:
/// `TEST_RUNNER_NAG_UI_PAUSE=1 xcodebuild test …`.
@MainActor
final class NagUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    // MARK: - Creating and editing

    func testEmptyStateLeadsToANewNag() {
        launch(scenario: "empty")
        XCTAssertTrue(app.staticTexts["Nothing to nag about"].waitForExistence(timeout: 5))
        app.buttons["New nag"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["New nag"].waitForExistence(timeout: 3))
    }

    func testCreatingANagStartsNaggingNow() {
        launch()
        app.navigationBars["Nags"].buttons["New nag"].tap()
        let title = app.textFields["What needs doing?"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.tap()
        title.typeText("Buy milk")
        pause()
        app.buttons["Save"].tap()

        XCTAssertTrue(status("Buy milk").waitForExistence(timeout: 3))
        XCTAssertTrue(status("Buy milk").label.hasPrefix("Due now"), status("Buy milk").label)
        XCTAssertEqual(check("Buy milk").value as? String, "due")
        pause()
    }

    func testSaveIsDisabledWithoutATitle() {
        launch()
        app.navigationBars["Nags"].buttons["New nag"].tap()
        XCTAssertFalse(app.buttons["Save"].isEnabled)
    }

    func testCustomTimesNagShowsEachTime() {
        launch()
        app.navigationBars["Nags"].buttons["New nag"].tap()
        let title = app.textFields["What needs doing?"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.tap()
        title.typeText("Vitamins")

        chooseRepeat("Custom")
        XCTAssertTrue(app.staticTexts["Times"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.switches["Start nagging now"].exists)
        pause()

        // First time: Mon, Wed, Fri.
        for day in ["Sunday", "Tuesday", "Thursday", "Saturday"] { weekday(day, time: 0).tap() }
        pause()

        // Second time: Tue, Thu.
        app.buttons["Add time"].tap()
        XCTAssertTrue(weekday("Monday", time: 1).waitForExistence(timeout: 3))
        for day in ["Sunday", "Monday", "Wednesday", "Friday", "Saturday"] { weekday(day, time: 1).tap() }
        pause()

        app.buttons["Save"].tap()
        let tags = app.staticTexts["tags.Vitamins"]
        XCTAssertTrue(tags.waitForExistence(timeout: 3))
        XCTAssertTrue(tags.label.contains("Mon, Wed, Fri"), tags.label)
        XCTAssertTrue(tags.label.contains("Tue, Thu"), tags.label)
        pause()
    }

    func testCustomTimesNeedADayToSave() {
        launch()
        app.navigationBars["Nags"].buttons["New nag"].tap()
        let title = app.textFields["What needs doing?"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.tap()
        title.typeText("Never")
        chooseRepeat("Custom")
        XCTAssertTrue(weekday("Sunday", time: 0).waitForExistence(timeout: 3))
        for day in ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"] {
            weekday(day, time: 0).tap()
        }
        XCTAssertFalse(app.buttons["Save"].isEnabled)
        XCTAssertTrue(app.staticTexts["Add at least one time, and pick at least one day for each."].exists)
    }

    func testEditingRenamesANag() {
        launch()
        app.staticTexts["Water the plants"].tap()
        XCTAssertTrue(app.navigationBars["Edit nag"].waitForExistence(timeout: 3))
        let title = app.textFields["What needs doing?"]
        title.tap()
        title.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        title.typeText("Water the ferns")
        app.buttons["Save"].tap()

        XCTAssertTrue(app.staticTexts["Water the ferns"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Water the plants"].exists)
        pause()
    }

    // MARK: - State transitions

    func testCompletingARepeatingNagCountsForToday() {
        launch()
        XCTAssertEqual(check("Take meds").value as? String, "due")
        pause()
        check("Take meds").tap()

        XCTAssertTrue(wait(for: check("Take meds"), value: "done"))
        XCTAssertTrue(status("Take meds").label.hasPrefix("Done today"), status("Take meds").label)
        pause()
    }

    func testSnoozingFromTheSwipeAction() {
        launch()
        pause()
        app.staticTexts["Take meds"].swipeLeft()
        app.buttons["Snooze"].tap()

        XCTAssertTrue(wait(for: check("Take meds"), value: "snoozed"))
        XCTAssertTrue(status("Take meds").label.hasPrefix("Snoozed until"), status("Take meds").label)
        pause()
    }

    func testCompletingFromTheSwipeAction() {
        launch()
        app.staticTexts["Take meds"].swipeRight()
        app.buttons["Done"].tap()
        XCTAssertTrue(wait(for: check("Take meds"), value: "done"))
        pause()
    }

    func testReopeningAFinishedNag() {
        launch()
        XCTAssertEqual(check("File taxes").value as? String, "done")
        pause()
        app.staticTexts["File taxes"].swipeLeft()
        app.buttons["Reopen"].tap()

        XCTAssertTrue(wait(for: check("File taxes"), value: "due"))
        XCTAssertTrue(status("File taxes").label.hasPrefix("Overdue"), status("File taxes").label)
        pause()
    }

    func testClearingDoneNagsKeepsRepeatingOnes() {
        launch()
        pause()
        app.buttons["Clear"].tap()
        XCTAssertTrue(waitForDisappearance(app.staticTexts["File taxes"]))
        XCTAssertTrue(app.staticTexts["Stretch"].exists)
        pause()
    }

    // MARK: - Long-press menu

    func testDuplicatingFromTheLongPressMenu() {
        launch()
        app.staticTexts["Water the plants"].press(forDuration: 1)
        let duplicate = app.buttons["Duplicate"]
        XCTAssertTrue(duplicate.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Delete"].exists)
        pause()
        duplicate.tap()

        XCTAssertTrue(app.staticTexts["Water the plants copy"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Water the plants"].exists)
        XCTAssertEqual(check("Water the plants copy").value as? String, "upcoming")
        pause()
    }

    func testDeletingFromTheLongPressMenu() {
        launch()
        app.staticTexts["Water the plants"].press(forDuration: 1)
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        pause()
        delete.tap()

        XCTAssertTrue(waitForDisappearance(app.staticTexts["Water the plants"]))
        XCTAssertTrue(app.staticTexts["Take meds"].exists)
        pause()
    }

    // MARK: - Links

    func testLinkOpensAPrefilledEditorAndSavesWithItsSource() throws {
        launch()
        app.open(try XCTUnwrap(URL(string: "nag://add?title=Reply+to+Sam&notes=From+my+notes&source=Muse&id=card-1")))

        let title = app.textFields["What needs doing?"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.value as? String, "Reply to Sam")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Muse'")).firstMatch.exists)
        pause()
        app.buttons["Save"].tap()

        let tags = app.staticTexts["tags.Reply to Sam"]
        XCTAssertTrue(tags.waitForExistence(timeout: 3))
        XCTAssertTrue(tags.label.contains("Muse"), tags.label)
        pause()
    }

    func testBadLinkExplainsWhatsWrong() throws {
        launch()
        app.open(try XCTUnwrap(URL(string: "nag://add?title=Oops&repeat=hourly")))
        XCTAssertTrue(app.alerts["Couldn't add that nag"].waitForExistence(timeout: 10))
        app.alerts.buttons["OK"].tap()
        XCTAssertFalse(app.staticTexts["Oops"].exists)
    }

    // MARK: - Helpers

    private func launch(scenario: String = "sample") {
        app = XCUIApplication()
        app.launchArguments = ["-NagUITesting"]
        app.launchEnvironment["NAG_UI_SCENARIO"] = scenario
        app.launch()
        XCTAssertTrue(app.navigationBars["Nags"].waitForExistence(timeout: 10))
        pause()
    }

    private func chooseRepeat(_ option: String) {
        let picker = app.descendants(matching: .any)["repeat"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.tap()
        let item = app.buttons[option].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.tap()
    }

    private func check(_ title: String) -> XCUIElement {
        app.buttons["complete.\(title)"]
    }

    private func status(_ title: String) -> XCUIElement {
        app.staticTexts["status.\(title)"]
    }

    /// The day button for `day` in the `time`-th custom time.
    private func weekday(_ day: String, time: Int) -> XCUIElement {
        app.buttons.matching(identifier: day).element(boundBy: time)
    }

    private func wait(for element: XCUIElement, value: String, timeout: TimeInterval = 3) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    /// Holds still so screen recordings show each state settle. No-op unless `NAG_UI_PAUSE` is set.
    private func pause() {
        guard let seconds = ProcessInfo.processInfo.environment["NAG_UI_PAUSE"].flatMap(Double.init), seconds > 0 else { return }
        Thread.sleep(forTimeInterval: seconds)
    }
}
