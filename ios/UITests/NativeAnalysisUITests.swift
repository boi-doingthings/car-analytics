import XCTest

/// Native chart navigation uses only an invented, throwaway archive.
final class NativeAnalysisUITests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        continueAfterFailure = false
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "book", withExtension: nil))
        root = FileManager.default.temporaryDirectory.appending(path: "analysis-ui-\(UUID().uuidString)/i20_book")
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: root)
    }
    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    }
    func test_patternsPerformanceAndHistoricalFuelAreNativeAndReachable() {
        let app = XCUIApplication()
        app.launchEnvironment["I20_DEBUG_BOOK"] = root.path
        app.launch()
        XCTAssertTrue(app.buttons["lastDrive"].waitForExistence(timeout: 45))
        app.tabBars.buttons["Lab"].tap()
        let studies = app.segmentedControls["labStudyPicker"]
        XCTAssertTrue(studies.waitForExistence(timeout: 10))
        XCTAssertTrue(studies.buttons["Patterns"].isSelected)
        XCTAssertTrue(app.staticTexts["When you drive"].exists)
        studies.buttons["Performance"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["performanceInsightsScreen"].waitForExistence(timeout: 5))
        studies.buttons["Patterns"].tap()
        XCTAssertTrue(app.staticTexts["When you drive"].waitForExistence(timeout: 5))
        app.buttons["openFuelScenario"].tap()
        XCTAssertTrue(app.sliders["Distance"].waitForExistence(timeout: 5))
        let fuelStudy = app.segmentedControls["fuelStudyPicker"]
        XCTAssertTrue(fuelStudy.waitForExistence(timeout: 5))
        fuelStudy.buttons["History & model"].tap()
        XCTAssertTrue(fuelStudy.buttons["History & model"].isSelected)
        XCTAssertTrue(app.staticTexts["Saved fuel window"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["fuelHistoryScreen"].exists)
        fuelStudy.buttons["Scenario"].tap()
        XCTAssertTrue(fuelStudy.buttons["Scenario"].isSelected)
        XCTAssertTrue(app.sliders["City-distance share"].waitForExistence(timeout: 5))
    }
}
