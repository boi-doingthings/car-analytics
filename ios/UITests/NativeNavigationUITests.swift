import XCTest

/// All UI checks use invented records copied into a throwaway archive; no login or iCloud access.
final class NativeNavigationUITests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "book", withExtension: nil))
        root = FileManager.default.temporaryDirectory.appending(path: "native-ui-\(UUID().uuidString)/i20_book")
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: root)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["I20_DEBUG_BOOK"] = root.path
        app.launch()
        return app
    }

    func test_nativeTabsTripDebriefAndDataQualityUseTheSameArchive() {
        let app = launch()
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["lastDrive"].waitForExistence(timeout: 45))
        app.tabBars.buttons["Trips"].tap()
        XCTAssertTrue(app.navigationBars["Trips"].waitForExistence(timeout: 5))
        let trip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "trip-")).firstMatch
        XCTAssertTrue(trip.waitForExistence(timeout: 10))
        trip.tap()
        XCTAssertTrue(app.navigationBars["Drive debrief"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Lab"].tap()
        app.buttons["openDataQuality"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["dataQualityScreen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Vehicle observation"].exists)
    }

    func test_scenarioAndLogbookAreReachableWithoutWebNavigation() {
        let app = launch()
        XCTAssertTrue(app.tabBars.buttons["Lab"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Lab"].tap()
        app.buttons["openFuelScenario"].tap()
        XCTAssertTrue(app.sliders["Distance"].waitForExistence(timeout: 5))
        app.sliders["Distance"].adjust(toNormalizedSliderPosition: 0.4)
        XCTAssertTrue(app.sliders["City-distance share"].exists)
        app.tabBars.buttons["Garage"].tap()
        let log = app.buttons["openLogbook"]
        for _ in 0..<4 where !log.isHittable { app.swipeUp() }
        XCTAssertTrue(log.isHittable)
        log.tap()
        XCTAssertTrue(app.buttons["refuelButton"].waitForExistence(timeout: 5))
    }
}
