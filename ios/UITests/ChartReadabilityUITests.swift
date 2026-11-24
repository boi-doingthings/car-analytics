import XCTest

final class ChartReadabilityUITests: XCTestCase {
    func test_exactWeekdayValuesHourlyInspectionAndEventGrouping() throws {
        continueAfterFailure = false
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "book", withExtension: nil))
        let root = FileManager.default.temporaryDirectory.appending(path: "readable-charts-\(UUID().uuidString)/i20_book")
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: root)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let app = XCUIApplication()
        app.launchEnvironment["I20_DEBUG_BOOK"] = root.path
        app.launchEnvironment["I20_DEBUG_READ_ONLY"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["lastDrive"].waitForExistence(timeout: 45))
        app.tabBars.buttons["Lab"].tap()

        let weekday = app.buttons["weekdayDistance-Monday"]
        reveal(weekday, app: app)
        XCTAssertTrue((weekday.value as? String)?.contains("km per calendar weekday") == true)
        weekday.tap()
        XCTAssertTrue(weekday.isSelected)
        capture(app, "Readable weekday comparison")

        reveal(app.staticTexts["Standing still by departure hour"], app: app)
        let inspector = app.buttons["idleHour-inspector"]
        reveal(inspector, app: app)
        inspector.tap()
        app.buttons["8am"].tap()
        XCTAssertTrue(app.staticTexts["idleHour-selection"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["idleHour-selection"].label.contains("8am:"))
        capture(app, "Full-day hourly profile with selection")

        let grouping = app.segmentedControls["eventExposureGrouping"]
        reveal(grouping, app: app)
        XCTAssertTrue(grouping.buttons["Event type"].isSelected)
        XCTAssertTrue(app.buttons["eventExposure-Harsh braking"].exists)
        XCTAssertTrue(app.buttons["eventExposure-Rapid acceleration"].exists)
        XCTAssertTrue(app.buttons["eventExposure-Overspeed alerts"].exists)
        grouping.buttons["Weekday"].tap()
        XCTAssertTrue(grouping.buttons["Weekday"].isSelected)
        XCTAssertTrue(app.buttons["eventExposure-Monday"].exists)
        XCTAssertFalse(app.buttons["eventExposure-Harsh braking"].exists)
        grouping.buttons["Event type"].tap()
        reveal(app.buttons["eventExposure-Harsh braking"], app: app)
        app.buttons["eventExposure-Harsh braking"].tap()
        XCTAssertTrue(app.buttons["eventExposure-Harsh braking"].isSelected)
        capture(app, "Provider event types and normalized evidence")
        app.terminate()
    }

    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<40 {
            let frame = element.exists ? element.frame : .zero
            let top = max(150, app.navigationBars.firstMatch.frame.maxY + 8)
            let bottom = app.tabBars.firstMatch.frame.minY - 12
            if element.exists && frame.height > 0 && frame.minY >= top && frame.maxY <= bottom { return }
            let down = frame != .zero && frame.minY < top
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: down ? 0.48 : 0.72))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: down ? 0.72 : 0.48)))
        }
        XCTFail("Control could not be brought fully into view: \(element). \(app.debugDescription)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
