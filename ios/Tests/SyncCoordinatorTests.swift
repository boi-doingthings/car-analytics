import XCTest
import I20Core
@testable import I20Logbook

/// A Bluelink account with no vehicles: login and collect succeed without writing any day files.
private struct EmptyAPI: BluelinkAPI {
    func vehicles() async throws -> (raw: Data, list: [Vehicle]) { (Data(), []) }
    func get(_ path: String) async throws -> Data { Data() }
    func post(_ path: String, json: [String: Any]) async throws -> Data { Data() }
}

@MainActor
final class SyncCoordinatorTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appending(path: "sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func fixtureBook() throws -> Book {
        let src = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "book", withExtension: nil))
        let dst = tmp.appending(path: "i20_book")
        try FileManager.default.copyItem(at: src, to: dst)
        return Book(root: dst)
    }

    func coordinator(book: Book?, login: @escaping SyncCoordinator.Login) -> SyncCoordinator {
        SyncCoordinator(book: { book }, credentials: { ("user", "pass") }, login: login,
                        runner: AnalyticsRunner(derivedDir: tmp.appending(path: "derived")),
                        collectorPause: .zero)
    }

    func test_syncRunsLoginCollectAnalyse() async throws {
        let book = try fixtureBook()
        let sync = coordinator(book: book) { _, _ in EmptyAPI() }
        sync.syncNow()
        XCTAssertTrue(sync.state.running)
        XCTAssertEqual(sync.state.step, "login")
        await sync.task?.value
        XCTAssertFalse(sync.state.running)
        XCTAssertNil(sync.state.error)
        XCTAssertNotNil(sync.state.lastSync)
        XCTAssertEqual(sync.state.issues, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sync.derivedDir.appending(path: "data.json").path))
    }

    func test_newRunClearsPreviousIssuesAndStats() async throws {
        let book = try fixtureBook()
        try book.writeAtomic("log/refuels/stray.json", Data("{}".utf8))
        var fail = false
        let sync = coordinator(book: book) { _, _ in
            if fail { throw BluelinkError.loginFailed }
            return EmptyAPI()
        }
        sync.syncNow()
        await sync.task?.value
        XCTAssertFalse(sync.state.issues.isEmpty)
        XCTAssertNotNil(sync.state.stats)

        fail = true
        sync.syncNow()
        XCTAssertEqual(sync.state.issues, [])
        XCTAssertNil(sync.state.stats)
        await sync.task?.value
        XCTAssertEqual(sync.state.error, SyncCoordinator.loginText)
        XCTAssertEqual(sync.state.issues, [], "an aborted run shows nothing from the last one")
        XCTAssertNil(sync.state.stats)
    }

    func test_errorsMapToHeaderText() async throws {
        let book = try fixtureBook()
        let cases: [(Error, String)] = [
            (BluelinkError.timeout, "Hyundai's server didn't respond. Try again in a few minutes."),
            (BluelinkError.loginFailed, "Bluelink login failed. Check your username and password in Settings."),
        ]
        for (err, text) in cases {
            let sync = coordinator(book: book) { _, _ in throw err }
            sync.syncNow()
            await sync.task?.value
            XCTAssertEqual(sync.state.error, text)
            XCTAssertFalse(sync.state.running)
        }
    }

    func test_derivedSaveFailureIsNotAFolderError() {
        XCTAssertEqual(SyncCoordinator.text(for: AnalyticsError.saveFailed("disk full")),
                       "Couldn't save the dashboard on this iPhone (disk full).")
        XCTAssertEqual(SyncCoordinator.text(for: AnalyticsError.stillDownloading(3)),
                       "3 files still downloading from iCloud \u{2014} sync again shortly.")
    }

    func test_stillDownloadingIsAnErrorAndDoesNotCountAsFinished() async throws {
        let book = try fixtureBook()
        try Data().write(to: book.root.appending(path: "raw/days/00000000-0000-4000-8000-000000000001/.20261006.json.icloud"))
        let runner = AnalyticsRunner(derivedDir: tmp.appending(path: "derived"))
        runner.downloadTimeout = 0.2
        let sync = SyncCoordinator(book: { book }, credentials: { ("u", "p") }, login: { _, _ in EmptyAPI() },
                                   runner: runner, collectorPause: .zero)
        sync.rebuild()
        await sync.task?.value
        XCTAssertEqual(sync.state.error, "1 file still downloading from iCloud \u{2014} sync again shortly.")
        XCTAssertEqual(sync.finishedRuns, 0)  // the dashboard is not reloaded
        XCTAssertEqual(sync.state.issues.count, 1)
    }

    func test_unreachableFolderMapsToFolderText() async throws {
        let gone = Book(root: tmp.appending(path: "missing/i20_book"))
        let sync = coordinator(book: gone) { _, _ in EmptyAPI() }
        sync.syncNow()
        await sync.task?.value
        XCTAssertEqual(sync.state.error, "Can't reach the i20_book folder in iCloud Drive.")
    }

    func test_syncIfStaleSkipsFreshSync() async throws {
        let book = try fixtureBook()
        try book.writeAtomic("state/last_sync.json", Data("{\"last_sync\": \"\(istTimestamp(Date()))\"}".utf8))
        var logins = 0
        let sync = coordinator(book: book) { _, _ in logins += 1; return EmptyAPI() }
        sync.syncIfStale()
        await sync.task?.value
        XCTAssertEqual(logins, 0)
        XCTAssertNotNil(sync.state.lastSync)
    }

    func test_rebuildRunsAnalyticsOnly() async throws {
        let book = try fixtureBook()
        var logins = 0
        let sync = coordinator(book: book) { _, _ in logins += 1; return EmptyAPI() }
        sync.rebuild()
        XCTAssertEqual(sync.state.step, "analyse")
        await sync.task?.value
        XCTAssertEqual(logins, 0)
        XCTAssertNil(sync.state.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sync.derivedDir.appending(path: "data.json").path))
    }
    func test_editsDuringSyncCoalesceIntoFollowupWithinSameTask() async throws {
        let book = try fixtureBook()
        var releaseLogin: (() -> Void)?
        var logins = 0
        let sync = coordinator(book: book) { _, _ in
            logins += 1
            await withCheckedContinuation { continuation in
                releaseLogin = { continuation.resume() }
            }
            return EmptyAPI()
        }
        sync.syncNow()
        for _ in 0..<100 where releaseLogin == nil { await Task.yield() }
        let release = try XCTUnwrap(releaseLogin)
        sync.rebuild()
        sync.rebuild()
        sync.rebuild()
        release()
        await sync.task?.value
        XCTAssertFalse(sync.state.running)
        XCTAssertNil(sync.state.error)
        XCTAssertEqual(logins, 1, "queued edits must never log in again")
        XCTAssertEqual(sync.finishedRuns, 1, "publish one UI refresh after the complete sequence")
        XCTAssertNotNil(sync.state.lastAnalysis)
        let generations = tmp.appending(path: "derived/generations")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: generations.path).count, 2,
                       "one original analysis plus one coalesced follow-up")
    }

    func test_pendingEditRebuildsCachedDataEvenWhenLoginFails() async throws {
        let book = try fixtureBook()
        let sync = coordinator(book: book) { _, _ in throw BluelinkError.loginFailed }
        sync.syncNow()
        sync.rebuild()
        await sync.task?.value
        XCTAssertEqual(sync.state.error, SyncCoordinator.loginText)
        XCTAssertNotNil(sync.state.lastAnalysis)
        XCTAssertEqual(sync.finishedRuns, 1, "native cached data must still refresh after the saved edit")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sync.derivedDir.appending(path: "data.json").path))
    }

    func test_switchingArchivesDoesNotExposePreviousCachedGeneration() async throws {
        let first = try fixtureBook()
        let otherRoot = tmp.appending(path: "other/i20_book")
        try FileManager.default.createDirectory(at: otherRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: first.root, to: otherRoot)
        let second = Book(root: otherRoot)
        var selected = first
        let sync = SyncCoordinator(book: { selected }, runner: AnalyticsRunner(derivedDir: tmp.appending(path: "derived")))
        sync.rebuild()
        await sync.task?.value
        XCTAssertTrue(sync.hasCurrentArchiveSnapshot)
        let previous = sync.derivedDir
        selected = second
        XCTAssertFalse(sync.hasCurrentArchiveSnapshot)
        XCTAssertNotEqual(sync.derivedDir, previous)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sync.derivedDir.appending(path: "data.json").path))
        sync.rebuild()
        await sync.task?.value
        XCTAssertTrue(sync.hasCurrentArchiveSnapshot)
        XCTAssertNotEqual(sync.derivedDir, previous)
    }

    func test_unknownLegacyCacheRequiresRebuildForSelectedArchive() async throws {
        let book = try fixtureBook()
        let root = tmp.appending(path: "derived")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appending(path: "data.json"))
        let sync = SyncCoordinator(book: { book }, runner: AnalyticsRunner(derivedDir: root))
        XCTAssertFalse(sync.hasCurrentArchiveSnapshot)
        XCTAssertNotEqual(sync.derivedDir, root)
        XCTAssertNil(sync.state.lastAnalysis)
    }

    func test_failedRebuildOfNewArchiveClearsPreviousArchiveTimestamps() async throws {
        let first = try fixtureBook()
        try first.writeAtomic("state/last_sync.json", Data(#"{"last_sync":"2026-10-05T20:00:00+05:30"}"#.utf8))
        var selected = first
        let sync = SyncCoordinator(book: { selected }, runner: AnalyticsRunner(derivedDir: tmp.appending(path: "derived")))
        sync.rebuild()
        await sync.task?.value
        XCTAssertNotNil(sync.state.lastAnalysis)
        XCTAssertNotNil(sync.state.lastSync)
        selected = Book(root: tmp.appending(path: "missing/i20_book"))
        sync.rebuild()
        XCTAssertNil(sync.state.lastAnalysis)
        XCTAssertNil(sync.state.lastSync)
        await sync.task?.value
        XCTAssertNotNil(sync.state.error)
        XCTAssertNil(sync.state.lastAnalysis)
        XCTAssertNil(sync.state.lastSync)
    }

}
