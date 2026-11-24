import XCTest
import UIKit

final class GarageHistoryUITests: XCTestCase {
    func test_readOnlyServiceHistoryAndMaintenanceStayNativeAndPreserveArchive() throws {
        continueAfterFailure = false
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "book", withExtension: nil))
        let root = FileManager.default.temporaryDirectory.appending(path: "garage-history-\(UUID().uuidString)/i20_book")
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: root)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let serviceID = "46964728-5984-4d43-8562-e66de617fe69"
        let recordURL = root.appending(path: "log/services/\(serviceID).json")
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
        record["photos"] = ["invoice.jpg"]
        try JSONSerialization.data(withJSONObject: record).write(to: recordURL)
        let photoFolder = root.appending(path: "log/services/\(serviceID)")
        try FileManager.default.createDirectory(at: photoFolder, withIntermediateDirectories: true)
        let inventedReceipt = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
        try XCTUnwrap(inventedReceipt.jpegData(compressionQuality: 0.8)).write(to: photoFolder.appending(path: "invoice.jpg"))
        func contents() throws -> [String: Data] {
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
            var result: [String: Data] = [:]
            for case let file as URL in enumerator where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                result[String(file.path.dropFirst(root.path.count))] = try Data(contentsOf: file)
            }
            return result
        }
        let before = try contents()
        let app = XCUIApplication()
        app.launchEnvironment["I20_DEBUG_BOOK"] = root.path
        app.launchEnvironment["I20_DEBUG_READ_ONLY"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["lastDrive"].waitForExistence(timeout: 45))
        app.tabBars.buttons["Garage"].tap()
        let history = app.buttons["openServiceHistory"]
        for _ in 0..<3 where !history.isHittable { app.swipeUp() }
        XCTAssertTrue(history.isHittable)
        history.tap()
        XCTAssertTrue(app.navigationBars["Service history"].waitForExistence(timeout: 5))
        let service = app.buttons["service-46964728-5984-4d43-8562-e66de617fe69"]
        XCTAssertTrue(service.waitForExistence(timeout: 10))
        service.tap()
        XCTAssertTrue(app.navigationBars["Record details"].waitForExistence(timeout: 5))
        let invoice = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value == %@", "INV-1", "INV-1")).firstMatch
        for _ in 0..<2 where !invoice.exists { app.swipeUp() }
        XCTAssertTrue(invoice.exists, app.debugDescription)
        XCTAssertFalse(app.buttons["save"].exists)
        let detailScreenshot = XCTAttachment(screenshot: app.screenshot())
        detailScreenshot.name = "Native service invoice details"
        detailScreenshot.lifetime = .keepAlways
        add(detailScreenshot)
        let attachment = app.buttons["Attachment 1"]
        for _ in 0..<4 where !attachment.isHittable { app.swipeUp() }
        XCTAssertTrue(attachment.isHittable)
        attachment.tap()
        XCTAssertTrue(app.images["Service invoice attachment"].waitForExistence(timeout: 15))
        for (current, parent) in [("Invoice attachment", "Record details"), ("Record details", "Service history"), ("Service history", "Garage")] {
            let bar = app.navigationBars[current]
            XCTAssertTrue(bar.exists, app.debugDescription)
            let back = bar.buttons.firstMatch
            XCTAssertFalse(back.frame.intersects(app.staticTexts["archiveReadOnlyBanner"].frame), "The archive banner must not cover Back")
            back.tap()
            let returned = app.navigationBars[parent].waitForExistence(timeout: 5)
            if !returned {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Service navigation after Back"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
            XCTAssertTrue(returned, app.debugDescription)
        }
        let plan = app.buttons["openMaintenancePlan"]
        for _ in 0..<3 where !plan.isHittable { app.swipeUp() }
        plan.tap()
        XCTAssertTrue(app.navigationBars["Maintenance plan"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Complete maintenance schedule"].exists)
        XCTAssertEqual(try contents(), before, "Native service exploration must not change any archive byte")
        app.terminate()
    }
}
