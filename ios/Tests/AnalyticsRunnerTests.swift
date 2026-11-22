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
            XCTAssertTrue(FileManager.default.fileExists(atPath: derived.appending(path: name).path), name)
        }
        XCTAssertEqual(try Data(contentsOf: derived.appending(path: "data.json")), out.data)
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

        let out = try await AnalyticsRunner(derivedDir: derived).run(book: book, today: "2026-10-26")

        XCTAssertNil(out.fuel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: derived.appending(path: "fuel.json").path))
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
}
