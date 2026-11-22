import XCTest
@testable import I20Logbook

@MainActor
final class SetupTests: XCTestCase {
    func defaults() -> UserDefaults {
        let name = "test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func test_wrongFolderNameIsRefusedAndNothingStored() {
        let d = defaults()
        let f = FolderAccess(defaults: d)
        f.picked(URL(fileURLWithPath: "/tmp/Documents"))
        XCTAssertNil(f.book)
        XCTAssertNil(d.data(forKey: FolderAccess.bookmarkKey))
        XCTAssertEqual(f.error, "Pick the i20_book folder in iCloud Drive")
    }

    func test_restoreWithoutBookmarkLeavesNoBook() {
        let f = FolderAccess(defaults: defaults())
        f.restore()
        XCTAssertNil(f.book)
    }

    func test_garbageBookmarkIsUnresolvable() {
        let d = defaults()
        d.set(Data([1, 2, 3]), forKey: FolderAccess.bookmarkKey)
        let f = FolderAccess(defaults: d)
        f.restore()
        XCTAssertNil(f.book)
    }

    let svc = "com.i20logbook.app.tests"

    func test_credentialsRoundTripAndClear() throws {
        Credentials.clear(service: svc)
        XCTAssertNil(Credentials.load(service: svc))
        try Credentials.save(username: "u", password: "p1", service: svc)
        try Credentials.save(username: "u", password: "p2", service: svc)
        XCTAssertEqual(Credentials.load(service: svc)?.1, "p2")
        Credentials.clear(service: svc)
        XCTAssertNil(Credentials.load(service: svc))
    }

    func test_expiryExtractedFromProfileBlob() {
        let xml = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>ExpirationDate</key><date>2026-11-02T10:00:00Z</date></dict></plist>"
        var blob = Data([0x30, 0x82, 0x01, 0xFF, 0x00])
        blob.append(Data(xml.utf8)); blob.append(Data([0x00, 0x9F, 0x11]))
        XCTAssertEqual(InstallInfo.expiry(inProfile: blob), ISO8601DateFormatter().date(from: "2026-11-02T10:00:00Z"))
        XCTAssertNil(InstallInfo.expiry(inProfile: Data([1, 2, 3])))
    }

    func test_fallbackIsExecutableModDatePlus7Days() throws {
        let f = FileManager.default.temporaryDirectory.appending(path: "exe-\(UUID().uuidString)")
        try Data([0]).write(to: f)
        let m = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: f.path)
        XCTAssertEqual(InstallInfo.fallbackDue(executable: f), m.addingTimeInterval(7 * 86400))
        XCTAssertNil(InstallInfo.fallbackDue(executable: nil))
    }

    func test_staleRefreshStoresFreshBookmark() {
        let d = defaults(); let f = FolderAccess(defaults: d)
        f.refreshIfStale(false) { Data([9]) }
        XCTAssertNil(d.data(forKey: FolderAccess.bookmarkKey))
        f.refreshIfStale(true) { Data([9]) }
        XCTAssertEqual(d.data(forKey: FolderAccess.bookmarkKey), Data([9]))
        XCTAssertNil(f.warning)
    }

    func test_staleRefreshFailureWarns() {
        struct Boom: Error {}
        let f = FolderAccess(defaults: defaults())
        f.refreshIfStale(true) { throw Boom() }
        XCTAssertEqual(f.warning, FolderAccess.refreshFailedMessage)
    }

    func test_failedRestoreDropsBookmarkAndExplains() {
        let d = defaults()
        d.set(Data([1, 2, 3]), forKey: FolderAccess.bookmarkKey)
        let f = FolderAccess(defaults: d)
        f.restore()
        XCTAssertNil(d.data(forKey: FolderAccess.bookmarkKey))
        XCTAssertEqual(f.error, FolderAccess.restoreFailedMessage)
    }
}
