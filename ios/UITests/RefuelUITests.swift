import XCTest

/// Refuel happy path in the simulator against a temp book (DEBUG harness `I20_DEBUG_BOOK`; offline stub
/// Bluelink account) — never the real iCloud book.
final class RefuelUITests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory.appending(path: "ui-\(UUID().uuidString)/i20_book")
        try FileManager.default.createDirectory(at: root.appending(path: "log"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func test_refuelHappyPath() throws {
        let app = XCUIApplication()
        app.launchEnvironment["I20_DEBUG_BOOK"] = root.path
        app.resetAuthorizationStatus(for: .location)
        app.launch()

        app.tabBars.buttons["Garage"].tap()
        let openLogbook = app.buttons["openLogbook"]
        for _ in 0..<5 where !openLogbook.isHittable { app.swipeUp() }
        openLogbook.tap()
        app.buttons["refuelButton"].tap()
        dismissLocationPrompt()

        type("3535.67", into: app.textFields["amount"])
        type("106.40", into: app.textFields["rate"])
        XCTAssertEqual(app.staticTexts["derived"].label, "= 33.23")
        type("12000", into: app.textFields["odometer"])
        type("UI Pump", into: app.textFields["station"])
        XCTAssertTrue(app.switches["fullTank"].isOn)
        XCTAssertTrue(app.buttons["save"].isEnabled)
        app.buttons["save"].tap()

        // Back on the list, the new entry is shown.
        let rowAppeared = app.staticTexts["UI Pump"].waitForExistence(timeout: 10)
        if !rowAppeared {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Refuel after save"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Refuel save accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(rowAppeared, app.debugDescription)

        // Exactly one entry file was written into the book, with the form's values.
        let dir = root.appending(path: "log/refuels")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }
        XCTAssertEqual(files.count, 1)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: dir.appending(path: files[0]))) as? [String: Any])
        XCTAssertEqual(obj["id"] as? String, String(files[0].dropLast(5)))
        XCTAssertEqual(obj["station"] as? String, "UI Pump")
        XCTAssertEqual(obj["amount"] as? Double, 3535.67)
        XCTAssertEqual(obj["rate"] as? Double, 106.4)
        XCTAssertTrue(obj["litres"] is NSNull, "the derived litres is shown, not stored")
        XCTAssertEqual(obj["odometer_km"] as? Double, 12000)
        XCTAssertEqual(obj["full_tank"] as? Bool, true)
        XCTAssertEqual(obj["missed"] as? Bool, false)
        XCTAssertTrue(obj["lat"] is NSNull, "location was denied, so no coordinates")
    }

    private func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
    }

    /// The when-in-use prompt appears the first time the form opens; deny it (the form works without it).
    private func dismissLocationPrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deny = springboard.alerts.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Don'")).firstMatch
        if deny.waitForExistence(timeout: 5) { deny.tap() }
    }
}

private extension XCUIElement {
    var isOn: Bool { (value as? String) == "1" }
}
