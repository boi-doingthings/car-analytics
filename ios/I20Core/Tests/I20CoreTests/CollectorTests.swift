import Foundation
import XCTest
@testable import I20Core

/// Fake Bluelink: canned responses, records every call. Day POSTs answer from `days[key]`
/// (default: an empty successful day), trip detail POSTs from `trips[tid]` (default: a 50-point route).
final class FakeAPI: BluelinkAPI, @unchecked Sendable {
    struct Call: Equatable { let method: String; let path: String; let body: String }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var vehicleList: [Vehicle]
    var vehiclesRaw = Data("{\"retCode\":\"S\",\"resMsg\":{\"vehicles\":[]}}".utf8)
    var gets: [String: Data] = [:]
    var days: [String: Data] = [:]
    var trips: [String: Data] = [:]

    init(vehicles: [Vehicle] = [Vehicle(id: "v1", ccs2: 0)]) { vehicleList = vehicles }

    var calls: [Call] { lock.withLock { _calls } }
    var dayPosts: [String] {
        calls.filter { $0.path.hasSuffix("/tripinfo") }.compactMap { c in
            (try? JSONSerialization.jsonObject(with: Data(c.body.utf8)) as? [String: Any])?["setTripDay"] as? String
        }
    }
    var tripPosts: [String] {
        calls.filter { $0.path.hasSuffix("/tripinfo/detail") }.compactMap { c in
            ((try? JSONSerialization.jsonObject(with: Data(c.body.utf8)) as? [String: Any])?["setServiceTID"])
                .flatMap { Collector.tidString($0) }
        }
    }

    func vehicles() async throws -> (raw: Data, list: [Vehicle]) { (vehiclesRaw, vehicleList) }

    func get(_ path: String) async throws -> Data {
        lock.withLock { _calls.append(Call(method: "GET", path: path, body: "")) }
        return gets[path] ?? Data("{\"retCode\":\"S\",\"resMsg\":{\"path\":\"\(path)\"}}".utf8)
    }

    func post(_ path: String, json: [String: Any]) async throws -> Data {
        let body = String(decoding: try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), as: UTF8.self)
        lock.withLock { _calls.append(Call(method: "POST", path: path, body: body)) }
        if path.hasSuffix("/tripinfo") {
            let key = json["setTripDay"] as! String
            return days[key] ?? FakeAPI.day(key, trips: [])
        }
        let tid = Collector.tidString(json["setServiceTID"]!)!
        return trips[tid] ?? FakeAPI.trip(points: 50)
    }

    static func day(_ key: String, trips: [String]) -> Data {
        let list = trips.map { "{\"serviceTID\":\"\($0)\",\"tripStartTime\":\"\(key)080000\",\"tripEndTime\":\"\(key)083000\"}" }
        return Data("{\"retCode\":\"S\",  \"resMsg\":{\"dayTripList\":[{\"tripDay\":\"\(key)\",\"tripList\":[\(list.joined(separator: ","))]}]}}".utf8)
    }

    static func trip(points: Int) -> Data {
        let pts = (0..<points).map { "{\"lat\":\($0),\"lon\":\($0)}" }
        return Data("{\"retCode\":\"S\",\"resMsg\":{\"tripInfo\":{\"tripList\":[\(pts.joined(separator: ","))]}}}".utf8)
    }
}

/// IST wall-clock time as a Date.
func ist(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date {
    var c = DateComponents()
    (c.year, c.month, c.day, c.hour, c.minute) = (y, mo, d, h, mi)
    c.timeZone = TimeZone(identifier: "Asia/Kolkata")
    return Calendar(identifier: .gregorian).date(from: c)!
}

final class CollectorTests: XCTestCase {
    var book: Book!
    var tmp: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appending(path: "i20collect-\(UUID().uuidString)")
        let root = tmp.appending(path: "i20_book")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        book = Book(root: root)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    // MARK: helpers

    func collector(_ api: FakeAPI, now: Date) -> Collector {
        var c = Collector(book: book, api: api, now: { now }, pause: .zero)
        c.downloadTimeout = 0.2
        return c
    }

    /// Saves a day file; `fetched` writes a sidecar, `mtime` sets the file date instead/as well.
    func saveDay(_ key: String, vid: String = "v1", fetched: Date? = nil, mtime: Date? = nil, body: Data? = nil) throws {
        let rel = "raw/days/\(vid)/\(key).json"
        try book.writeAtomic(rel, body ?? FakeAPI.day(key, trips: []))
        if let fetched {
            try book.writeAtomic("raw/days/\(vid)/\(key).meta.json",
                                 Data("{\n  \"fetched_at\": \"\(istTimestamp(fetched))\"\n}".utf8))
        }
        if let mtime { try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: book.url(rel).path) }
    }

    func placeholder(_ rel: String) throws {
        let u = book.url(rel)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: u.deletingLastPathComponent().appending(path: "." + u.lastPathComponent + ".icloud"))
    }

    func days(from: String, to: String) -> [String] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Kolkata")
        f.dateFormat = "yyyyMMdd"
        var d = f.date(from: from)!
        var out: [String] = []
        while f.string(from: d) <= to { out.append(f.string(from: d)); d = d.addingTimeInterval(86400) }
        return out
    }

    // MARK: tests

    func test_isFinal() {
        XCTAssertTrue(Collector.isFinal(fetchedAt: ist(2026, 10, 8, 0, 5), day: "20261001"))
        XCTAssertFalse(Collector.isFinal(fetchedAt: ist(2026, 10, 7, 23, 59), day: "20261001"))
        XCTAssertFalse(Collector.isFinal(fetchedAt: nil, day: "20261001"))
    }

    func test_resumeFromMatchesPython() throws {
        let api = FakeAPI()
        let c = collector(api, now: ist(2026, 10, 22))
        // No files -> today - 7.
        XCTAssertEqual(try c.resumeFrom(vid: "v1", today: "20261022"), "20261015")

        // A 3-week gap after a 30 Sep sync: everything fetched on 30 Sep (sidecars).
        for k in days(from: "20260901", to: "20260930") { try saveDay(k, fetched: ist(2026, 9, 30, 20)) }
        XCTAssertEqual(try c.resumeFrom(vid: "v1", today: "20261021"), "20260924")

        // Same via file modification dates only (no sidecars), as collect.py sees it.
        for k in days(from: "20260901", to: "20260930") { try saveDay(k, vid: "v2", mtime: ist(2026, 9, 30, 20)) }
        XCTAssertEqual(try c.resumeFrom(vid: "v2", today: "20261021"), "20260924")

        // A hole on 20260610 in an otherwise final run.
        for k in days(from: "20260601", to: "20260620") where k != "20260610" {
            try saveDay(k, vid: "v3", fetched: ist(2026, 7, 1))
        }
        XCTAssertEqual(try c.resumeFrom(vid: "v3", today: "20261022"), "20260610")

        // Sidecars are not day files; a sidecar alone doesn't count.
        try book.writeAtomic("raw/days/v4/20260101.meta.json", Data("{\"fetched_at\": \"2026-01-02T00:00:00+05:30\"}".utf8))
        XCTAssertEqual(try c.resumeFrom(vid: "v4", today: "20261022"), "20261015")
    }

    func test_finalDayNotRefetched() async throws {
        let api = FakeAPI()
        let original = Data("{\"retCode\":\"S\",\"resMsg\":{\"dayTripList\":[]},\"original\":true}".utf8)
        try saveDay("20260930", fetched: ist(2026, 10, 1))           // not final -> resume starts here
        try saveDay("20261001", fetched: ist(2026, 10, 9), body: original)  // fetched 8 days after: final
        let metaBefore = try book.read("raw/days/v1/20261001.meta.json")
        let stats = try await collector(api, now: ist(2026, 10, 25)).run(snapshot: false)
        XCTAssertEqual(stats.from, "20260930")
        XCTAssertEqual(stats.to, "20261025")
        XCTAssertFalse(api.dayPosts.contains("20261001"))
        XCTAssertEqual(api.dayPosts, days(from: "20260930", to: "20261025").filter { $0 != "20261001" })
        XCTAssertEqual(try book.read("raw/days/v1/20261001.json"), original)
        XCTAssertEqual(try book.read("raw/days/v1/20261001.meta.json"), metaBefore)
        XCTAssertEqual(stats.daysSkipped, 1)
        XCTAssertEqual(stats.daysFetched, 25)
        XCTAssertTrue(book.exists("state/last_sync.json"))
    }

    func test_finalByModificationDateWithoutSidecar() async throws {
        let api = FakeAPI()
        try saveDay("20261010", mtime: ist(2026, 10, 18))  // final by mtime, no sidecar
        try saveDay("20261009", mtime: ist(2026, 10, 10))  // non-final by mtime
        _ = try await collector(api, now: ist(2026, 10, 25)).run(snapshot: false)
        XCTAssertEqual(api.dayPosts.first, "20261009")
        XCTAssertFalse(api.dayPosts.contains("20261010"))
        XCTAssertFalse(book.exists("raw/days/v1/20261010.meta.json"))
    }

    func test_nonFinalDayRefetchedAndSidecarUpdated() async throws {
        let api = FakeAPI()
        try saveDay("20261020", fetched: ist(2026, 10, 21))
        let fresh = Data("{\"retCode\":\"S\" , \"resMsg\":{\"dayTripList\":[]},\"fresh\":1}".utf8)
        api.days["20261020"] = fresh
        let now = ist(2026, 10, 25, 9, 30)
        let stats = try await collector(api, now: now).run(snapshot: false)
        XCTAssertTrue(api.dayPosts.contains("20261020"))
        XCTAssertEqual(try book.read("raw/days/v1/20261020.json"), fresh)  // verbatim
        let meta = try book.read("raw/days/v1/20261020.meta.json")
        XCTAssertEqual(String(decoding: meta, as: UTF8.self), "{\n  \"fetched_at\": \"2026-10-25T09:30:00+05:30\"\n}")
        XCTAssertEqual(stats.errors, [])
        let sync = try JSONSerialization.jsonObject(with: try book.read("state/last_sync.json")) as! [String: String]
        XCTAssertEqual(sync, ["last_sync": "2026-10-25T09:30:00+05:30"])
        // The day POST body matches collect.py.
        let call = api.calls.first { $0.path == "vehicles/v1/tripinfo" && $0.body.contains("20261020") }
        XCTAssertEqual(call?.body, "{\"setTripDay\":\"20261020\",\"tripPeriodType\":1}")
    }

    func test_tripRefetchOnlyWhenRouteMissing() async throws {
        let api = FakeAPI()
        // Final day 20261001 (in range because 20260930 is not final) with a 1-point trip C and a missing trip D.
        try saveDay("20260930", fetched: ist(2026, 10, 1))
        try saveDay("20261001", fetched: ist(2026, 10, 9), body: FakeAPI.day("20261001", trips: ["C", "D"]))
        try book.writeAtomic("raw/trips/v1/C.json", FakeAPI.trip(points: 1))
        // Non-final day 20261020 with a 1-point trip A and a 50-point trip B.
        try saveDay("20261020", fetched: ist(2026, 10, 21))
        api.days["20261020"] = FakeAPI.day("20261020", trips: ["A", "B"])
        try book.writeAtomic("raw/trips/v1/A.json", FakeAPI.trip(points: 1))
        let b = FakeAPI.trip(points: 50)
        try book.writeAtomic("raw/trips/v1/B.json", b)
        let newA = FakeAPI.trip(points: 7)
        api.trips["A"] = newA

        let stats = try await collector(api, now: ist(2026, 10, 25)).run(snapshot: false)
        XCTAssertEqual(api.tripPosts.sorted(), ["A", "D"])
        XCTAssertEqual(try book.read("raw/trips/v1/A.json"), newA)
        XCTAssertEqual(try book.read("raw/trips/v1/B.json"), b)
        XCTAssertEqual(try book.read("raw/trips/v1/C.json"), FakeAPI.trip(points: 1))
        XCTAssertTrue(book.exists("raw/trips/v1/D.json"))
        XCTAssertEqual(stats.tripsFetched, 2)
        XCTAssertEqual(stats.tripsSkipped, 2)
        // The trip detail POST body matches collect.py.
        let call = api.calls.first { $0.path == "vehicles/v1/tripinfo/detail" && $0.body.contains("\"A\"") }
        XCTAssertEqual(call?.body, "{\"setServiceTID\":\"A\",\"setTripDay\":\"20261020\",\"setTripStartTime\":\"20261020080000\","
            + "\"tripEndTime\":\"20261020083000\",\"tripPeriodType\":1,\"tripStartTime\":\"20261020080000\"}")
    }

    /// Synthetic day in the real API's shape (2026-10 India): serviceTID is a JSON number, times are strings.
    static let numericDay = Data("""
        {"retCode":"S","resCode":"0000","resMsg":{"tripPeriodType":1,"dayTripList":[{"tripDay":"20261024",
        "dayTripCnt":2,"tripDrvTime":40,"tripIdleTime":3,"tripDist":21,"tripAvgSpeed":31.5,"tripMaxSpeed":72,
        "startLat":12.5,"startLon":77.5,"endLat":12.6,"endLon":77.6,"tripList":[
        {"tripStartTime":"20261024083126","tripStartCoord":{"lat":12.5,"lon":77.5},"tripEndTime":"20261024091502",
        "tripEndCoord":{"lat":12.6,"lon":77.6},"serviceTID":20261024083126},
        {"tripStartTime":"20261024180000","tripStartCoord":{"lat":12.6,"lon":77.6},"tripEndTime":"20261024183000",
        "tripEndCoord":{"lat":12.5,"lon":77.5},"serviceTID":20261024180000}]}]},"msgId":"x"}
        """.utf8)

    func test_numericServiceTIDFetchedAndNamedByDigits() async throws {
        let api = FakeAPI()
        api.days["20261024"] = Self.numericDay
        let existing = FakeAPI.trip(points: 50)
        try book.writeAtomic("raw/trips/v1/20261024180000.json", existing)
        let stats = try await collector(api, now: ist(2026, 10, 25)).run(snapshot: false)
        XCTAssertEqual(stats.errors, [])
        XCTAssertEqual(api.tripPosts, ["20261024083126"])
        let call = api.calls.first { $0.path == "vehicles/v1/tripinfo/detail" }
        XCTAssertEqual(call?.body, "{\"setServiceTID\":20261024083126,\"setTripDay\":\"20261024\","
            + "\"setTripStartTime\":\"20261024083126\",\"tripEndTime\":\"20261024091502\",\"tripPeriodType\":1,"
            + "\"tripStartTime\":\"20261024083126\"}")
        XCTAssertTrue(fm.fileExists(atPath: book.url("raw/trips/v1/20261024083126.json").path))
        XCTAssertEqual(try book.read("raw/trips/v1/20261024180000.json"), existing)
        XCTAssertEqual(stats.tripsFetched, 1)
        XCTAssertEqual(stats.tripsSkipped, 1)
    }

    func test_tidString() {
        XCTAssertEqual(Collector.tidString(NSNumber(value: Int64(20261024083126))), "20261024083126")
        XCTAssertEqual(Collector.tidString(NSNumber(value: 20261024083126.0)), "20261024083126")
        XCTAssertEqual(Collector.tidString("abc"), "abc")
        XCTAssertNil(Collector.tidString(NSNumber(value: 1.5)))
        XCTAssertNil(Collector.tidString(NSNumber(value: true)))
        XCTAssertNil(Collector.tidString(NSNull()))
        let parsed = try! JSONSerialization.jsonObject(with: Data("[20261024083126, 2.0261024083126e13, true]".utf8)) as! [Any]
        XCTAssertEqual(parsed.map { Collector.tidString($0) }, ["20261024083126", "20261024083126", nil])
    }

    func test_failedDayResponseNotWritten() async throws {
        let api = FakeAPI()
        api.days["20261024"] = Data("{\"retCode\":\"F\",\"resCode\":\"9999\"}".utf8)
        api.days["20261023"] = Data("<html>bad gateway</html>".utf8)
        api.trips["X"] = Data("{\"retCode\":\"F\"}".utf8)
        api.days["20261022"] = FakeAPI.day("20261022", trips: ["X"])
        let stats = try await collector(api, now: ist(2026, 10, 25)).run(snapshot: false)
        XCTAssertFalse(book.exists("raw/days/v1/20261024.json"))
        XCTAssertFalse(book.exists("raw/days/v1/20261024.meta.json"))
        XCTAssertFalse(book.exists("raw/days/v1/20261023.json"))
        XCTAssertFalse(book.exists("raw/trips/v1/X.json"))
        XCTAssertEqual(stats.errors.count, 3)
        XCTAssertTrue(stats.errors.contains { $0.hasPrefix("day 20261024: ") && $0.contains("9999") })
        XCTAssertTrue(stats.errors.contains { $0.hasPrefix("day 20261023: ") })
        XCTAssertTrue(stats.errors.contains { $0.hasPrefix("trip X: ") })
        XCTAssertEqual(stats.daysFetched, 6)
    }

    func test_placeholderDayIsNotRefetched() async throws {
        let api = FakeAPI()
        // now = 25 Oct, floor = 18 Oct. 20260930 isn't final, so the range starts there.
        try saveDay("20260930", fetched: ist(2026, 10, 1))
        // Old day present only as a placeholder (file can't be downloaded), real final sidecar: never fetched.
        try placeholder("raw/days/v1/20261001.json")
        try book.writeAtomic("raw/days/v1/20261001.meta.json",
                             Data("{\n  \"fetched_at\": \"2026-10-09T10:00:00+05:30\"\n}".utf8))
        // Old day with a real (non-final by mtime) file but a placeholder sidecar: final, but its trips are checked.
        try saveDay("20261005", mtime: ist(2026, 10, 6), body: FakeAPI.day("20261005", trips: ["E"]))
        try placeholder("raw/days/v1/20261005.meta.json")
        // Recent-window days: placeholders can never be final, so they are fetched and written.
        try placeholder("raw/days/v1/20261020.json")
        try placeholder("raw/days/v1/20261020.meta.json")
        try saveDay("20261021")
        try placeholder("raw/days/v1/20261021.meta.json")
        let fresh = FakeAPI.day("20261020", trips: [])
        api.days["20261020"] = fresh

        let stats = try await collector(api, now: ist(2026, 10, 25)).run(snapshot: false)
        for k in ["20261001", "20261005"] { XCTAssertFalse(api.dayPosts.contains(k), k) }
        XCTAssertFalse(fm.fileExists(atPath: book.url("raw/days/v1/20261001.json").path))  // placeholder untouched
        XCTAssertFalse(fm.fileExists(atPath: book.url("raw/days/v1/20261005.meta.json").path))
        XCTAssertEqual(api.tripPosts, ["E"])
        for k in ["20261002", "20261020", "20261021"] { XCTAssertTrue(api.dayPosts.contains(k), k) }
        XCTAssertEqual(try book.read("raw/days/v1/20261020.json"), fresh)
        XCTAssertTrue(fm.fileExists(atPath: book.url("raw/days/v1/20261020.meta.json").path))
        XCTAssertTrue(fm.fileExists(atPath: book.url("raw/days/v1/20261021.meta.json").path))
        XCTAssertEqual(stats.daysSkipped, 2)
        XCTAssertEqual(stats.errors.sorted(), [
            "day 20261001: iCloud placeholder not downloaded, left untouched",
            "day 20261005: iCloud placeholder not downloaded, left untouched",
        ])
        // resumeFrom treats old placeholders as final too.
        try placeholder("raw/days/v9/20260101.json")
        XCTAssertEqual(try collector(api, now: ist(2026, 10, 25)).resumeFrom(vid: "v9", today: "20261025"), "20260102")
    }

    func test_placeholderSkipsInResumeWalkAreReported() async throws {
        let api = FakeAPI()
        try placeholder("raw/days/v1/20260901.json")
        try placeholder("raw/days/v1/20260902.json")
        let stats = try await collector(api, now: ist(2026, 10, 25)).run(snapshot: false)
        XCTAssertEqual(stats.from, "20260903")
        XCTAssertEqual(stats.errors, ["2 days before 20260903: iCloud placeholder not downloaded, left untouched"])
    }

    func test_corruptFinalDayIsReported() async throws {
        let api = FakeAPI()
        try saveDay("20260930", fetched: ist(2026, 10, 1))
        try saveDay("20261001", fetched: ist(2026, 10, 9), body: Data("not json".utf8))
        let stats = try await collector(api, now: ist(2026, 10, 25)).run(snapshot: false)
        XCTAssertFalse(api.dayPosts.contains("20261001"))
        XCTAssertEqual(try book.read("raw/days/v1/20261001.json"), Data("not json".utf8))
        XCTAssertEqual(stats.errors, ["day 20261001: saved file unreadable, trips not checked"])
    }

    func test_placeholderTripOnRecentDayNotOverwritten() async throws {
        let api = FakeAPI()
        api.days["20261024"] = FakeAPI.day("20261024", trips: ["P"])
        try placeholder("raw/trips/v1/P.json")
        let stats = try await collector(api, now: ist(2026, 10, 25)).run(snapshot: false)
        XCTAssertEqual(api.tripPosts, [])
        XCTAssertFalse(fm.fileExists(atPath: book.url("raw/trips/v1/P.json").path))
        XCTAssertEqual(stats.tripsSkipped, 1)
        XCTAssertEqual(stats.errors, ["trip P: iCloud placeholder not downloaded, left untouched"])
    }

    func test_dayKeysUseIST() async throws {
        // Force the process timezone both ways Foundation reads it (TZ for TimeZone.current,
        // NSTimeZone.default for formatters/calendars without an explicit zone).
        let savedDefault = NSTimeZone.default
        let savedTZ = ProcessInfo.processInfo.environment["TZ"]
        setenv("TZ", "America/Los_Angeles", 1)
        NSTimeZone.resetSystemTimeZone()
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        defer {
            if let savedTZ { setenv("TZ", savedTZ, 1) } else { unsetenv("TZ") }
            NSTimeZone.resetSystemTimeZone()
            NSTimeZone.default = savedDefault
        }
        XCTAssertEqual(TimeZone.current.identifier, "America/Los_Angeles")
        let api = FakeAPI()
        let now = ist(2026, 10, 25, 1, 0)  // still 24 Oct in Los Angeles
        let c = collector(api, now: now)
        let stats = try await c.run(snapshot: true)
        XCTAssertEqual(stats.to, "20261025")
        XCTAssertEqual(stats.from, "20261018")
        XCTAssertEqual(api.dayPosts, days(from: "20261018", to: "20261025"))
        XCTAssertTrue(book.exists("raw/snapshots/v1/20261025T010000/vehicles.json"))
        XCTAssertTrue(Collector.isFinal(fetchedAt: ist(2026, 10, 25, 0, 30), day: "20261018"))
        XCTAssertFalse(Collector.isFinal(fetchedAt: ist(2026, 10, 24, 23, 30), day: "20261018"))
    }

    func test_snapshotWritesFourFilesVerbatim() async throws {
        let api = FakeAPI(vehicles: [Vehicle(id: "v1", ccs2: 1), Vehicle(id: "v2", ccs2: 0)])
        let bodies = [
            "vehicles": Data("{\"retCode\":\"S\",  \"resMsg\":{\"vehicles\":[{\"x\":1.50}]}}\n".utf8),
            "vehicles/v1/ccs2/carstatus/latest": Data("{ \"retCode\" : \"S\", \"resMsg\": {\"odo\": 1.0} }".utf8),
            "vehicles/v1/location/park": Data("{\"retCode\":\"S\",\"resMsg\":{\"lat\":12.9716000}}".utf8),
            "vehicles/v1/setting/alert/maintenance": Data("{\"retCode\":\"S\",\"resMsg\":{\"ü\":\"é\"}}".utf8),
            "vehicles/v2/status/latest": Data("{\"retCode\":\"S\",\"resMsg\":{\"v\":2}}".utf8),
            "vehicles/v2/location/park": Data("{\"retCode\":\"F\",\"resMsg\":null}".utf8),
        ]
        api.gets = bodies
        let stats = try await collector(api, now: ist(2026, 10, 25, 14, 5)).run(snapshot: true)
        let dir1 = "raw/snapshots/v1/20261025T140500"
        XCTAssertEqual(try book.list(dir1), ["location_park.json", "maintenance_alert.json", "status_latest.json", "vehicles.json"])
        XCTAssertEqual(try book.read(dir1 + "/vehicles.json"), bodies["vehicles"])
        XCTAssertEqual(try book.read(dir1 + "/status_latest.json"), bodies["vehicles/v1/ccs2/carstatus/latest"])
        XCTAssertEqual(try book.read(dir1 + "/location_park.json"), bodies["vehicles/v1/location/park"])
        XCTAssertEqual(try book.read(dir1 + "/maintenance_alert.json"), bodies["vehicles/v1/setting/alert/maintenance"])
        let dir2 = "raw/snapshots/v2/20261025T140500"
        XCTAssertEqual(try book.read(dir2 + "/status_latest.json"), bodies["vehicles/v2/status/latest"])
        XCTAssertFalse(book.exists(dir2 + "/location_park.json"))
        XCTAssertTrue(stats.errors.contains { $0.hasPrefix("location_park: ") })
        let gets = api.calls.filter { $0.method == "GET" }.map(\.path)
        XCTAssertEqual(Array(gets.prefix(4)), ["vehicles", "vehicles/v1/ccs2/carstatus/latest",
                                              "vehicles/v1/location/park", "vehicles/v1/setting/alert/maintenance"])
        XCTAssertEqual(gets.count, 8)
    }

    func test_noSnapshotMakesNoGets() async throws {
        let api = FakeAPI()
        _ = try await collector(api, now: ist(2026, 10, 25)).run(snapshot: false)
        XCTAssertEqual(api.calls.filter { $0.method == "GET" }, [])
        XCTAssertFalse(book.exists("raw/snapshots"))
    }

    func test_unreachableBookThrowsAndWritesNothing() async throws {
        try fm.removeItem(at: book.root)
        let api = FakeAPI()
        do {
            _ = try await collector(api, now: ist(2026, 10, 25)).run(snapshot: false)
            XCTFail("expected a throw")
        } catch BookError.unreachable {}
        XCTAssertFalse(fm.fileExists(atPath: book.root.path))
    }
}

/// Opt-in real-login smoke test: skipped unless `I20_SMOKE=1`. Read-only (login + vehicles), no Book
/// writes; prints only the vehicle count and the first vehicle's ccs2 flag.
final class BluelinkSmokeTests: XCTestCase {
    func test_realLoginAndVehicles() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["I20_SMOKE"] == "1", "set I20_SMOKE=1 to run the real-login smoke test")
        guard let user = env["BLUELINK_USERNAME"], let pass = env["BLUELINK_PASSWORD"], !user.isEmpty, !pass.isEmpty else {
            XCTFail("BLUELINK_USERNAME / BLUELINK_PASSWORD not set")
            return
        }
        let client = BluelinkClient(session: URLSession(configuration: .ephemeral))
        try await client.login(username: user, password: pass)
        let (_, list) = try await client.vehicles()
        print("smoke: vehicles=\(list.count) first.ccs2=\(list.first.map { String($0.ccs2) } ?? "none")")
        XCTAssertFalse(list.isEmpty)
    }
}
