import XCTest
import I20Core
@testable import I20Logbook

final class AnalyticsRunnerTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appending(path: "runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Copies the synthetic fixture book (5 days, 3 trips, 2 snapshots, 3 refuels, 1 service; built by
    /// Tests/Fixtures/make_fixture_book.py through tools/migrate.py) to a temp `i20_book`.
    func fixtureBook() throws -> Book {
        let src = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "book", withExtension: nil))
        let dst = tmp.appending(path: "i20_book")
        try FileManager.default.copyItem(at: src, to: dst)
        return Book(root: dst)
    }

    func test_runsOnFixtureBook() async throws {
        let book = try fixtureBook()
        let before = try book.allFiles(under: "")
        let derived = tmp.appending(path: "derived")
        let runner = AnalyticsRunner(derivedDir: derived)

        let out = try await runner.run(book: book, today: "2026-10-26")

        let data = try XCTUnwrap(try JSONSerialization.jsonObject(with: out.data) as? [String: Any])
        let totals = try XCTUnwrap(data["totals"] as? [String: Any])
        XCTAssertEqual(totals["trips"] as? Int, 3)
        XCTAssertNotNil(data["running_cost"])
        let fuel = try XCTUnwrap(out.fuel)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: fuel) as? [String: Any])
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: out.performance) as? [String: Any])
        XCTAssertEqual(runner.issues, [])

        // Written to derived/, nothing added to the book.
        for name in ["data.json", "fuel.json", "performance.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: runner.derivedDir.appending(path: name).path), name)
        }
        XCTAssertEqual(try Data(contentsOf: runner.derivedDir.appending(path: "data.json")), out.data)
        XCTAssertEqual(try book.allFiles(under: ""), before)
    }

    func test_unreadableFilesAndNewerEntriesAreReportedNotFatal() async throws {
        let book = try fixtureBook()
        try book.writeAtomic("raw/trips/00000000-0000-4000-8000-000000000001/broken.json", Data("{nope".utf8))
        try book.writeAtomic("log/refuels/00000000-0000-4000-8000-0000000000ff.json", Data(#"{"schema": 2, "id": "00000000-0000-4000-8000-0000000000ff"}"#.utf8))
        let runner = AnalyticsRunner(derivedDir: tmp.appending(path: "derived"))

        let out = try await runner.run(book: book, today: "2026-10-26")

        let data = try XCTUnwrap(try JSONSerialization.jsonObject(with: out.data) as? [String: Any])
        XCTAssertEqual((data["totals"] as? [String: Any])?["trips"] as? Int, 3)
        XCTAssertEqual(runner.issues.count, 2, "\(runner.issues)")
        XCTAssertTrue(runner.issues.contains { $0.contains("broken.json") })
        XCTAssertTrue(runner.issues.contains { $0.contains("0000000000ff.json") })
    }

    func test_conflictCopiesAndHandEditedEntriesAreReported() async throws {
        let book = try fixtureBook()
        let id = try XCTUnwrap(try book.list("log/refuels").first { isUUIDJSON($0) })
        try book.writeAtomic("log/refuels/\(id.dropLast(5)) 2.json", try book.read("log/refuels/\(id)"))
        // Decodes as nothing useful in JS: no date. Swift reports it as unreadable; JS's warning for the same
        // entry is not repeated.
        let hand = "00000000-0000-4000-8000-0000000000ee"
        try book.writeAtomic("log/refuels/\(hand).json", Data(#"{"schema": 1, "id": "\#(hand)"}"#.utf8))
        let runner = AnalyticsRunner(derivedDir: tmp.appending(path: "derived"))

        let out = try await runner.run(book: book, today: "2026-10-26")

        XCTAssertNotNil(out.fuel, "one bad file must not blank the fuel page")
        XCTAssertEqual(runner.issues.count, 2, "\(runner.issues)")
        XCTAssertTrue(runner.issues.contains { $0.contains(" 2.json") && $0.contains("duplicate") })
        XCTAssertTrue(runner.issues.contains { $0.contains("\(hand).json") })
    }

    func test_jsWarningsSurfaceUnlessAlreadyReported() {
        let ws = ["skipping entry abc: missing or invalid date", "skipping entry ?: missing or invalid date", "skipping entry def: x"]
        let kept = AnalyticsRunner.newWarnings(ws, besides: ["log/refuels/abc.json: couldn't be read, left out"])
        XCTAssertEqual(kept, [ws[1], ws[2]])
    }

    private func isUUIDJSON(_ n: String) -> Bool { n.count == 41 && n.hasSuffix(".json") }

    func test_noRefuelsRemovesStaleFuelOutput() async throws {
        let book = try fixtureBook()
        for name in try book.list("log/refuels") { try book.delete("log/refuels/\(name)") }
        let derived = tmp.appending(path: "derived")
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: derived.appending(path: "fuel.json"))

        let runner = AnalyticsRunner(derivedDir: derived)
        let out = try await runner.run(book: book, today: "2026-10-26")

        XCTAssertNil(out.fuel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runner.derivedDir.appending(path: "fuel.json").path))
        let cachedWithoutFuel = try await runner.runIfNeeded(book: book, today: "2026-10-26")
        XCTAssertFalse(cachedWithoutFuel)
    }

    func test_placeholderKeepsLastOutputsAndReportsDownloading() async throws {
        let book = try fixtureBook()
        // An iCloud placeholder for a day that never downloads (outside iCloud the download can't start).
        let dir = book.root.appending(path: "raw/days/00000000-0000-4000-8000-000000000001")
        try Data().write(to: dir.appending(path: ".20261006.json.icloud"))
        let derived = tmp.appending(path: "derived")
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        let good = Data(#"{"good": true}"#.utf8)
        for name in ["data.json", "fuel.json", "performance.json"] { try good.write(to: derived.appending(path: name)) }
        let runner = AnalyticsRunner(derivedDir: derived)
        runner.downloadTimeout = 0.2

        do {
            _ = try await runner.run(book: book, today: "2026-10-26")
            XCTFail("expected stillDownloading")
        } catch let e as AnalyticsError {
            XCTAssertEqual(e, .stillDownloading(1))
            XCTAssertEqual(e.errorDescription, "1 file still downloading from iCloud \u{2014} sync again shortly.")
        }
        for name in ["data.json", "fuel.json", "performance.json"] {
            XCTAssertEqual(try Data(contentsOf: derived.appending(path: name)), good, name)
        }
        XCTAssertEqual(runner.issues, ["raw/days/00000000-0000-4000-8000-000000000001/20261006.json: still downloading from iCloud"])
    }

    func test_issuesResetWhenARunThrowsEarly() async throws {
        let book = try fixtureBook()
        try book.writeAtomic("raw/trips/00000000-0000-4000-8000-000000000001/broken.json", Data("{nope".utf8))
        let runner = AnalyticsRunner(derivedDir: tmp.appending(path: "derived"))
        _ = try await runner.run(book: book, today: "2026-10-26")
        XCTAssertEqual(runner.issues.count, 1)

        try FileManager.default.removeItem(at: book.root)  // folder gone: the next run throws before analysing
        do {
            _ = try await runner.run(book: book, today: "2026-10-26")
            XCTFail("expected unreachable")
        } catch {
            XCTAssertEqual(error as? BookError, .unreachable)
        }
        XCTAssertEqual(runner.issues, [])
    }

    func test_todayIsISTWhateverTheDeviceZone() {
        // 2026-10-25 20:00 UTC is already 26 Oct in India.
        let d = Date(timeIntervalSince1970: 1_792_958_400)
        XCTAssertEqual(AnalyticsRunner.istDay(d), "2026-10-26")
    }
    func test_failedPageKeepsEntirePreviousGeneration() async throws {
        let book = try fixtureBook()
        let root = tmp.appending(path: "derived")
        let runner = AnalyticsRunner(derivedDir: root)
        let previous = try await runner.run(book: book, today: "2026-10-26")
        let directory = runner.derivedDir
        let manifest = try Data(contentsOf: root.appending(path: "current.json"))
        let badScript = tmp.appending(path: "failed.js")
        // Even when two pages produced valid data, one failed page must prevent all publication.
        try Data("""
            globalThis.I20Analytics = { runAll: function() {
                return { data: {revision: "partial"}, performance: {revision: "partial"}, fuel: null,
                         errors: [{page: "fuel", message: "test failure"}], warnings: [] };
            }};
            """.utf8).write(to: badScript)
        let failed = AnalyticsRunner(derivedDir: root, script: badScript)
        do {
            _ = try await failed.run(book: book, today: "2026-10-26")
            XCTFail("expected page failure")
        } catch {
            XCTAssertEqual(error as? AnalyticsError, .failed(["fuel: test failure"]))
        }
        XCTAssertEqual(failed.derivedDir, directory)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "current.json")), manifest)
        XCTAssertEqual(try Data(contentsOf: directory.appending(path: "data.json")), previous.data)
        XCTAssertEqual(try Data(contentsOf: directory.appending(path: "performance.json")), previous.performance)
        XCTAssertEqual(try Data(contentsOf: directory.appending(path: "fuel.json")), previous.fuel)
    }

    func test_successfulGenerationsAreCompleteAndOldReaderRemainsValid() async throws {
        let book = try fixtureBook()
        let runner = AnalyticsRunner(derivedDir: tmp.appending(path: "derived"))
        let first = try await runner.run(book: book, today: "2026-10-26")
        let firstDirectory = runner.derivedDir
        XCTAssertNotNil(runner.publishedAt)
        XCTAssertTrue(runner.matches(book))
        let manifestText = try String(contentsOf: tmp.appending(path: "derived/current.json"), encoding: .utf8)
        XCTAssertFalse(manifestText.contains(book.root.path), "the local cache must not record a personal folder path")
        for name in try book.list("log/refuels") { try book.delete("log/refuels/\(name)") }
        _ = try await runner.run(book: book, today: "2026-10-26")
        XCTAssertNotEqual(runner.derivedDir, firstDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runner.derivedDir.appending(path: "fuel.json").path))
        XCTAssertEqual(try Data(contentsOf: firstDirectory.appending(path: "data.json")), first.data)
        XCTAssertEqual(try Data(contentsOf: firstDirectory.appending(path: "fuel.json")), first.fuel)
    }

    func test_cancellationDoesNotSwitchGenerationAndCleansUnpublishedDirectory() async throws {
        let root = tmp.appending(path: "derived")
        let store = AnalyticsGeneration(root: root)
        let old = Data("old".utf8)
        try store.publish(data: old, fuel: old, performance: old)
        let directory = store.directory
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try store.publish(data: Data("new".utf8), fuel: nil, performance: Data("new".utf8))
        }
        do { try await task.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(store.directory, directory)
        XCTAssertEqual(try Data(contentsOf: directory.appending(path: "data.json")), old)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "generations").path).count, 1)
    }

    func test_manifestCannotEscapeCacheDirectory() throws {
        let root = tmp.appending(path: "derived")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"schema":1,"generation":"../../outside","publishedAt":0}"#.utf8)
            .write(to: root.appending(path: "current.json"))
        XCTAssertEqual(AnalyticsGeneration(root: root).directory, root)
    }

    func test_failedManifestWritePreservesPublishedDataAndCleansStaging() throws {
        let root = tmp.appending(path: "derived")
        let store = AnalyticsGeneration(root: root)
        let data = Data("old".utf8)
        try store.publish(data: data, fuel: data, performance: data)
        let directory = store.directory
        let previous = try Data(contentsOf: root.appending(path: "current.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        XCTAssertThrowsError(try store.publish(data: Data("new".utf8), fuel: nil, performance: Data("new".utf8)))
        XCTAssertEqual(store.directory, directory)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "current.json")), previous)
        XCTAssertEqual(try Data(contentsOf: directory.appending(path: "data.json")), data)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "generations").path).count, 1)
    }

    func test_generationRetentionKeepsCurrentTwoPreviousAndRecentReaders() throws {
        let root = tmp.appending(path: "derived")
        let store = AnalyticsGeneration(root: root)
        let data = Data("{}".utf8)
        try store.publish(data: data, fuel: nil, performance: data)
        let current = store.directory
        let now = Date()
        var previous: [URL] = []
        for days in [5.0, 4.0, 3.0, 2.0, 0.5] {
            let directory = root.appending(path: "generations/\(UUID().uuidString.lowercased())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appending(path: "data.json"))
            try data.write(to: directory.appending(path: "performance.json"))
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-days * 86400)], ofItemAtPath: directory.path)
            previous.append(directory)
        }
        // An incomplete revision left by a crash is also removed only after the grace period.
        let abandoned = root.appending(path: "generations/\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3 * 86400)], ofItemAtPath: abandoned.path)
        store.prune(now: now)
        XCTAssertEqual(store.directory, current)
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        for (index, directory) in previous.enumerated() {
            XCTAssertEqual(FileManager.default.fileExists(atPath: directory.path), index >= 3)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
    }

    func test_passiveAnalysisReusesMetadataDayAndScriptMatchedGeneration() async throws {
        let book = try fixtureBook()
        let root = tmp.appending(path: "derived")
        let runner = AnalyticsRunner(derivedDir: root)
        let first = try await runner.runIfNeeded(book: book, today: "2026-10-26")
        XCTAssertTrue(first)
        let directory = runner.derivedDir
        let published = runner.publishedAt
        for _ in 0..<4 {
            let changed = try await runner.runIfNeeded(book: book, today: "2026-10-26", onRebuild: {
                XCTFail("An unchanged cache must not report a recalculation")
            })
            XCTAssertFalse(changed)
        }
        XCTAssertEqual(runner.derivedDir, directory)
        XCTAssertEqual(runner.publishedAt, published)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "generations").path).count, 1)
        try book.writeAtomic("log/services/synthetic-photo.jpg", Data("not an analytical input".utf8))
        let photoOnly = try await runner.runIfNeeded(book: book, today: "2026-10-26")
        XCTAssertFalse(photoOnly)
    }

    func test_passiveAnalysisInvalidatesForSourceAddEditAndDelete() async throws {
        let book = try fixtureBook()
        let runner = AnalyticsRunner(derivedDir: tmp.appending(path: "derived"))
        _ = try await runner.runIfNeeded(book: book, today: "2026-10-26")
        let entry = Maintenance(date: "2026-10-01", category: .wash, cost: 200)
        try save(entry, in: book)
        let added = try await runner.runIfNeeded(book: book, today: "2026-10-26")
        XCTAssertTrue(added)
        let path = "log/maintenance/\(entry.id).json"
        var updated = try book.read(path)
        updated.append(Data(" ".utf8))
        try book.writeAtomic(path, updated)
        let edited = try await runner.runIfNeeded(book: book, today: "2026-10-26")
        XCTAssertTrue(edited)
        // A same-size touch still invalidates through modification metadata.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)],
                                             ofItemAtPath: book.url(path).path)
        let touched = try await runner.runIfNeeded(book: book, today: "2026-10-26")
        XCTAssertTrue(touched)
        try book.delete(path)
        let deleted = try await runner.runIfNeeded(book: book, today: "2026-10-26")
        XCTAssertTrue(deleted)
        let unchanged = try await runner.runIfNeeded(book: book, today: "2026-10-26")
        XCTAssertFalse(unchanged)
    }

    func test_passiveAnalysisInvalidatesForCalendarDayScriptAndMissingOutputs() async throws {
        let book = try fixtureBook()
        let script = tmp.appending(path: "analytics-copy.js")
        let source = try XCTUnwrap(Bundle.main.url(forResource: "analytics", withExtension: "js"))
        try FileManager.default.copyItem(at: source, to: script)
        let runner = AnalyticsRunner(derivedDir: tmp.appending(path: "derived"), script: script)
        _ = try await runner.runIfNeeded(book: book, today: "2026-10-26")
        let nextDay = try await runner.runIfNeeded(book: book, today: "2026-10-27")
        XCTAssertTrue(nextDay)
        var code = try Data(contentsOf: script)
        code.append(Data("\n// synthetic script revision\n".utf8))
        try code.write(to: script)
        let newScript = try await runner.runIfNeeded(book: book, today: "2026-10-27")
        XCTAssertTrue(newScript)
        for name in ["data.json", "fuel.json", "performance.json"] {
            try FileManager.default.removeItem(at: runner.derivedDir.appending(path: name))
            let missingOutput = try await runner.runIfNeeded(book: book, today: "2026-10-27")
            XCTAssertTrue(missingOutput, "\(name) must exist before the cache can be reused")
        }
    }

    func test_legacyGenerationWithoutInputStampIsCertifiedOnlyAfterRebuild() async throws {
        let book = try fixtureBook()
        let root = tmp.appending(path: "derived")
        let runner = AnalyticsRunner(derivedDir: root)
        _ = try await runner.run(book: book, today: "2026-10-26")
        let manifestURL = root.appending(path: "current.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest.removeValue(forKey: "inputs")
        manifest.removeValue(forKey: "files")
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let upgraded = try await runner.runIfNeeded(book: book, today: "2026-10-26")
        XCTAssertTrue(upgraded)
        let again = try await runner.runIfNeeded(book: book, today: "2026-10-26")
        XCTAssertFalse(again)
    }

    func test_sourceChangedDuringAnalysisCannotCertifyNewerInputs() async throws {
        let book = try fixtureBook()
        let root = tmp.appending(path: "derived")
        let runner = AnalyticsRunner(derivedDir: root)
        _ = try await runner.run(book: book, today: "2026-10-26")
        let previous = runner.derivedDir
        let oldManifest = try Data(contentsOf: root.appending(path: "current.json"))
        let path = try XCTUnwrap(try book.allFiles(under: "raw").first { $0.hasSuffix(".json") && !$0.hasSuffix(".meta.json") })
        let changing = AnalyticsRunner(derivedDir: root, beforePublication: {
            var bytes = try book.read(path)
            bytes.append(Data(" ".utf8))
            try book.writeAtomic(path, bytes)
        })
        do {
            _ = try await changing.run(book: book, today: "2026-10-26")
            XCTFail("expected concurrent-source rejection")
        } catch { XCTAssertEqual(error as? AnalyticsError, .sourceChanged) }
        XCTAssertEqual(changing.derivedDir, previous)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "current.json")), oldManifest)
        let caughtUp = try await runner.runIfNeeded(book: book, today: "2026-10-26")
        XCTAssertTrue(caughtUp, "the rejected run must not falsely stamp the newer archive as analysed")
    }

    func test_placeholderArrivalInvalidatesWithoutReplacingPreviousCache() async throws {
        let book = try fixtureBook()
        let root = tmp.appending(path: "derived")
        let runner = AnalyticsRunner(derivedDir: root)
        _ = try await runner.run(book: book, today: "2026-10-26")
        let previous = runner.derivedDir
        let placeholder = book.root.appending(path: "raw/.pending.json.icloud")
        try Data().write(to: placeholder)
        runner.downloadTimeout = 0.01
        do {
            _ = try await runner.runIfNeeded(book: book, today: "2026-10-26")
            XCTFail("new placeholder must invalidate the cached signature")
        } catch { XCTAssertEqual(error as? AnalyticsError, .stillDownloading(1)) }
        XCTAssertEqual(runner.derivedDir, previous)
    }

    func test_scriptChangedDuringAnalysisCannotPublishAnOutdatedCertification() async throws {
        let book = try fixtureBook()
        let root = tmp.appending(path: "derived")
        let script = tmp.appending(path: "script-changing.js")
        let original = try XCTUnwrap(Bundle.main.url(forResource: "analytics", withExtension: "js"))
        try FileManager.default.copyItem(at: original, to: script)
        let runner = AnalyticsRunner(derivedDir: root, script: script)
        _ = try await runner.run(book: book, today: "2026-10-26")
        let previous = runner.derivedDir
        let changing = AnalyticsRunner(derivedDir: root, script: script, beforePublication: {
            var bytes = try Data(contentsOf: script)
            bytes.append(Data("\n// changed during evaluation\n".utf8))
            try bytes.write(to: script)
        })
        do {
            _ = try await changing.run(book: book, today: "2026-10-26")
            XCTFail("expected changed script rejection")
        } catch { XCTAssertEqual(error as? AnalyticsError, .sourceChanged) }
        XCTAssertEqual(changing.derivedDir, previous)
        let caughtUp = try await runner.runIfNeeded(book: book, today: "2026-10-26")
        XCTAssertTrue(caughtUp)
    }

    func test_materializedFileWithShadowPlaceholderSettlesToCachedAnalysis() async throws {
        let book = try fixtureBook()
        let runner = AnalyticsRunner(derivedDir: tmp.appending(path: "derived"))
        _ = try await runner.run(book: book, today: "2026-10-26")
        let path = try XCTUnwrap(try book.allFiles(under: "log/refuels").first { $0.hasSuffix(".json") })
        let real = book.url(path)
        let placeholder = real.deletingLastPathComponent().appending(path: "." + real.lastPathComponent + ".icloud")
        let before = try book.read(path)
        try Data().write(to: placeholder)
        let changed = try await runner.runIfNeeded(book: book, today: "2026-10-26")
        XCTAssertFalse(changed, "a shadow marker is irrelevant while the actual input is materialized")
        _ = try await runner.run(book: book, today: "2026-10-26")
        for _ in 0..<3 {
            let again = try await runner.runIfNeeded(book: book, today: "2026-10-26")
            XCTAssertFalse(again)
        }
        XCTAssertEqual(try book.read(path), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: placeholder.path), "analysis never edits archive metadata")
    }

}
