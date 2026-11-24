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

    private func launch(readOnly: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["I20_DEBUG_BOOK"] = root.path
        if readOnly { app.launchEnvironment["I20_DEBUG_READ_ONLY"] = "1" }
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
    func test_readOnlyBrowsingAndExplicitWriteConsentLeaveArchiveUnchanged() throws {
        func contents() throws -> [String: Data] {
            let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
            var result: [String: Data] = [:]
            for case let file as URL in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                result[String(file.path.dropFirst(root.path.count))] = try Data(contentsOf: file)
            }
            return result
        }
        let before = try contents()
        let app = launch(readOnly: true)
        let manageAccess = app.buttons["manageArchiveAccess"]
        let accessExists = manageAccess.waitForExistence(timeout: 20)
        if !accessExists {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Read-only launch accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(accessExists, "Read-only access control missing. \(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["archiveReadOnlyBanner"].exists)
        app.tabBars.buttons["Garage"].tap()
        XCTAssertFalse(app.buttons["garageAddRefuel"].isEnabled)
        XCTAssertFalse(app.buttons["garageAddService"].isEnabled)
        XCTAssertFalse(app.buttons["garageAddExpense"].isEnabled)
        manageAccess.tap()
        let writes = app.switches["archiveWritesToggle"]
        let automatic = app.switches["automaticCollectionToggle"]
        XCTAssertTrue(writes.waitForExistence(timeout: 5))
        XCTAssertEqual(writes.value as? String, "0")
        XCTAssertFalse(automatic.isEnabled)

        // The toggle's accessibility wrapper spans its whole row; its switch is at the trailing edge.
        writes.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let consentAlert = app.alerts["Allow changes to this archive?"]
        XCTAssertTrue(consentAlert.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(consentAlert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Make and verify a separate backup first")).firstMatch.exists)
        let consentScreen = XCTAttachment(screenshot: app.screenshot())
        consentScreen.name = "Explicit archive-write consent"
        consentScreen.lifetime = .keepAlways
        add(consentScreen)
        let consent = consentAlert.buttons.matching(identifier: "confirmArchiveWrites").firstMatch
        XCTAssertTrue(consent.exists)
        XCTAssertEqual(consent.label, "Allow changes")
        // UIKit exposes duplicate button wrappers here. A physical tap still must grant consent.
        consent.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(writes.value as? String, "1")
        XCTAssertTrue(automatic.isEnabled)
        XCTAssertEqual(automatic.value as? String, "0", "Allowing archive changes must not enable automatic collection")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["garageAddRefuel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["garageAddRefuel"].isEnabled)

        // A fresh Settings presentation keeps the access control naturally visible for revocation.
        app.buttons["openSettings"].tap()
        XCTAssertTrue(writes.waitForExistence(timeout: 5))
        writes.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(writes.value as? String, "0")
        XCTAssertFalse(automatic.isEnabled)
        for _ in 0..<2 { app.collectionViews.firstMatch.swipeUp() }
        let rebuild = app.buttons["syncOrRebuildButton"]
        XCTAssertTrue(rebuild.isHittable)
        XCTAssertTrue(rebuild.isEnabled)
        XCTAssertEqual(rebuild.label, "Rebuild analysis")
        rebuild.tap()
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["archiveReadOnlyBanner"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["garageAddRefuel"].isEnabled)
        XCTAssertEqual(try contents(), before, "browsing, rebuilding, granting and revoking writes must not edit the archive")
    }

}
