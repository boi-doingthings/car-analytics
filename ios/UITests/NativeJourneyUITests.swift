import XCTest

/// Calendar, map and replay checks against invented records only.
final class NativeJourneyUITests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "book", withExtension: nil))
        root = FileManager.default.temporaryDirectory.appending(path: "journey-ui-\(UUID().uuidString)/i20_book")
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: root)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["I20_DEBUG_BOOK"] = root.path
        app.launchEnvironment["I20_DEBUG_READ_ONLY"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["lastDrive"].waitForExistence(timeout: 45))
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let bottom = app.tabBars.firstMatch.frame.minY - 12
        let top = max(150, app.navigationBars.firstMatch.frame.maxY + 12)
        let viewport = CGRect(x: 12, y: top, width: app.frame.width - 24, height: bottom - top)
        func safelyVisible() -> Bool {
            element.exists && element.isHittable && viewport.contains(element.frame)
        }
        for _ in 0..<12 where !safelyVisible() {
            // Use the outer margin, avoiding embedded maps/charts, and reverse
            // if an earlier drag moved this control above the usable viewport.
            let moveDown = element.exists && element.frame.midY < viewport.midY
            let start = CGVector(dx: 0.98, dy: moveDown ? 0.40 : 0.70)
            let end = CGVector(dx: 0.98, dy: moveDown ? 0.64 : 0.46)
            app.coordinate(withNormalizedOffset: start).press(forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: end))
        }
        XCTAssertTrue(safelyVisible(), "Control frame \(element.frame); usable viewport \(viewport). \(app.debugDescription)")
    }

    func test_calendarHasMonthlyDistanceAndRecordedDayJourneys() {
        let app = launch()
        app.tabBars.buttons["Trips"].tap()
        app.buttons["openDrivingActivity"].tap()
        XCTAssertTrue(app.navigationBars["Driving activity"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["monthlyDistanceChart"].exists)
        let day = app.buttons["historyDay-2026-10-05"]
        reveal(day, in: app)
        day.tap()
        let trip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "historyTrip-")).firstMatch
        reveal(trip, in: app)
        let tapGeometry = XCTAttachment(string: "Trip link frame: \(trip.frame); tab bar frame: \(app.tabBars.firstMatch.frame); centre tap: \(trip.frame.midX), \(trip.frame.midY)\n\(app.debugDescription)")
        tapGeometry.name = "Calendar trip tap geometry"
        tapGeometry.lifetime = .keepAlways
        add(tapGeometry)
        trip.tap()
        XCTAssertTrue(app.navigationBars["Drive debrief"].waitForExistence(timeout: 5))
        let slider = app.sliders["tripReplaySlider"]
        reveal(slider, in: app)
        slider.adjust(toNormalizedSliderPosition: 0.6)
        // Swift Charts exposes both a container and a plot with this identifier.
        // Require a real plot rectangle on screen instead of the noninteractive
        // container's hittable flag, which remains false even for visible charts.
        let plots = app.descendants(matching: .any).matching(identifier: "tripSpeedChart")
        let viewport = CGRect(x: 0, y: 140, width: app.frame.width, height: app.frame.height - 240)
        func visiblePlot() -> XCUIElement? {
            plots.allElementsBoundByIndex.first {
                $0.frame.width <= app.frame.width && $0.frame.intersection(viewport).height >= 80
            }
        }
        for _ in 0..<6 where visiblePlot() == nil {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.68))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.42)))
        }
        XCTAssertNotNil(visiblePlot(), app.debugDescription)
    }

    func test_atlasScrubsChangesLayerAndPausesOnLeavingTab() {
        let app = launch()
        app.tabBars.buttons["Atlas"].tap()
        let play = app.buttons["atlasReplayPlay"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: play)
        waitForExpectations(timeout: 15)
        app.sliders["atlasScrubber"].adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertTrue(app.staticTexts["atlasReplayDate"].exists)
        app.segmentedControls["atlasMode"].buttons["Density"].tap()
        play.tap()
        XCTAssertEqual(play.label, "Pause time-lapse")
        app.tabBars.buttons["Trips"].tap()
        app.tabBars.buttons["Atlas"].tap()
        XCTAssertEqual(play.label, "Play time-lapse")
        app.buttons["atlasFilters"].tap()
        XCTAssertTrue(app.navigationBars["Atlas filters"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["atlasFromDate"].exists)
        app.buttons["atlasAllHistory"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["atlasMapDetails"].exists)
        let cursor = app.buttons["atlasCursorTrip"]
        reveal(cursor, in: app)
        cursor.tap()
        XCTAssertTrue(app.navigationBars["Drive debrief"].waitForExistence(timeout: 5))
    }
}
