import XCTest
@testable import I20Logbook

final class AnalyticsSnapshotTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "native-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ object: [String: Any], named name: String) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: directory.appending(path: name))
    }

    private func trip(_ id: String, day: String = "2026-10-05", start: String = "08:00:00",
                      end: String = "08:30:00", km: Any = 20.0,
                      origin: String = "Home", destination: String = "Work") -> [String: Any] {
        ["id": id, "start": "\(day)T\(start)", "end": "\(day)T\(end)", "km": km,
         "drive": 25, "idle": 5, "avg": 48, "max": 60, "route": true,
         "from": origin, "to": destination, "events": [1, 0, 0]]
    }

    func test_missingFuelRemainsUnknownAndStatusAgeIsNotRebuildAge() throws {
        try write(["generated_at": "2026-11-20T12:00:00", "status": ["as_of": "2026-10-05T20:00:00", "fuel_pct": NSNull()],
                   "trips": [trip("a")]], named: "data.json")
        let snapshot = try AnalyticsSnapshot.load(from: directory)
        XCTAssertNil(snapshot.fuel)
        XCTAssertNil(snapshot.overview.status?.fuelPercent)
        XCTAssertEqual(snapshot.latestObservationDate, AnalyticsDate.parse("2026-10-05T20:00:00"))
        XCTAssertNil(snapshot.latestTrip?.estimatedFuelCost)
        XCTAssertEqual(snapshot.overview.services.count, 0)
    }

    func test_tripJoinPreservesRawDistanceAndRejectsInvalidCoordinates() throws {
        try write(["trips": [trip("older", day: "2026-10-01"), trip("newer")],
                   "routes": ["newer": [[12.9, 77.5, 40, 0], [300, 77, 40, 60], [12.91, 77.51, 42, 120]]]], named: "data.json")
        try write(["trips": [["id": "newer", "km": 20.7, "est_l": 1.8, "cost": 180.0]]], named: "fuel.json")
        try write(["trips": [["trip_id": "newer", "km": 20.7, "elapsed_min": 30.0]]], named: "performance.json")
        let snapshot = try AnalyticsSnapshot.load(from: directory)
        XCTAssertEqual(snapshot.trips.map(\.id), ["newer", "older"])
        let latest = try XCTUnwrap(snapshot.latestTrip)
        XCTAssertEqual(latest.distanceKM, 20)
        XCTAssertEqual(latest.correctedDistanceKM, 20.7)
        XCTAssertEqual(latest.estimatedFuelCost, 180)
        XCTAssertEqual(latest.coordinates.count, 2)
        XCTAssertEqual(latest.routeSegments.count, 2, "Invalid source coordinates must break the drawn line")
        XCTAssertEqual(latest.coordinates.last?.elapsedSeconds, 120)
        XCTAssertEqual(latest.events, 1)
    }

    func test_periodWindowUsesIndiaCalendarAndNeverIncludesFutureOrOldTrips() throws {
        try write(["trips": [trip("today"), trip("yesterday", day: "2026-10-04"),
                              trip("old", day: "2026-10-03"), trip("future", start: "22:00:00", end: "22:30:00")]], named: "data.json")
        let snapshot = try AnalyticsSnapshot.load(from: directory)
        let anchor = try XCTUnwrap(AnalyticsDate.parse("2026-10-05T12:00:00"))
        let summary = snapshot.periodSummary(days: 2, endingOn: anchor)
        XCTAssertEqual(summary.tripCount, 2)
        XCTAssertEqual(summary.distanceKM, 40)
        XCTAssertEqual(summary.elapsedMinutes, 60)
        XCTAssertEqual(try XCTUnwrap(summary.idleShare), 1.0 / 6, accuracy: 1e-9)
        XCTAssertNil(summary.estimatedFuelCost)
        XCTAssertEqual(summary.fuelCostTripCount, 0)
        XCTAssertEqual(summary.daily.map(\.day), ["2026-10-04", "2026-10-05"])
        let empty = snapshot.periodSummary(days: 7, endingOn: try XCTUnwrap(AnalyticsDate.parse("2026-11-01T12:00:00")))
        XCTAssertEqual(empty.tripCount, 0)
        XCTAssertNil(empty.distanceKM)
        XCTAssertEqual(empty.daily.count, 0, "Missing archive dates cannot be plotted as known zero driving")
    }

    func test_partialDistanceDoesNotBecomeCompleteTotal() throws {
        try write(["trips": [trip("known"), trip("unknown", km: NSNull())]], named: "data.json")
        let snapshot = try AnalyticsSnapshot.load(from: directory)
        let summary = snapshot.periodSummary(days: 7, endingOn: try XCTUnwrap(AnalyticsDate.parse("2026-10-05T12:00:00")))
        XCTAssertEqual(summary.tripCount, 2)
        XCTAssertEqual(summary.distanceTripCount, 1)
        XCTAssertNil(summary.distanceKM)
        XCTAssertNil(summary.daily.first?.distanceKM)
    }

    func test_corruptOptionalOutputThrowsRatherThanPretendingNoFuel() throws {
        try write(["trips": []], named: "data.json")
        try Data("not JSON".utf8).write(to: directory.appending(path: "fuel.json"))
        XCTAssertThrowsError(try AnalyticsSnapshot.load(from: directory))
    }

    func test_comparisonRequiresSupportAndExcludesReverseFutureAndDifferentDistance() throws {
        let target = trip("target", day: "2026-10-16") // Friday
        let days = ["2026-10-05", "2026-10-06", "2026-10-07", "2026-10-08"]
        var records = (0..<10).map { trip("matched-\($0)", day: days[$0 % days.count]) }
        records += [target, trip("reverse", origin: "Work", destination: "Home"),
                    trip("future", day: "2026-10-19"), trip("far", km: 40),
                    trip("late", start: "15:00:00", end: "15:30:00")]
        try write(["trips": records], named: "data.json")
        let snapshot = try AnalyticsSnapshot.load(from: directory)
        let selected = try XCTUnwrap(snapshot.trips.first { $0.id == "target" })
        let comparison = snapshot.compare(selected)
        XCTAssertTrue(comparison.isSupported)
        XCTAssertEqual(comparison.tripCount, 10)
        XCTAssertEqual(comparison.dateCount, 4)
        XCTAssertEqual(comparison.medianMinutes, 30)
        XCTAssertEqual(comparison.differenceMinutes, 0)
        XCTAssertTrue(comparison.method.contains("Traffic and weather are not controlled"))
    }

    func test_comparisonSuppressesManyTripsFromOneDate() throws {
        let records = (0..<12).map { trip("same-day-\($0)") } + [trip("target", day: "2026-10-16")]
        try write(["trips": records], named: "data.json")
        let snapshot = try AnalyticsSnapshot.load(from: directory)
        let comparison = snapshot.compare(try XCTUnwrap(snapshot.latestTrip))
        XCTAssertFalse(comparison.isSupported)
        XCTAssertNil(comparison.medianMinutes)
        XCTAssertEqual(comparison.tripCount, 12)
        XCTAssertEqual(comparison.dateCount, 1)
    }


    func test_routeDisplayBreaksTimeGapsAndCoordinateJumps() throws {
        try write(["trips": [trip("route")], "routes": ["route": [
            [12.90, 77.50, 40, 0], [12.901, 77.501, 40, 60],
            [12.902, 77.502, 40, 300], [13.5, 78.5, 40, 360]
        ]]], named: "data.json")
        let latest = try XCTUnwrap(AnalyticsSnapshot.load(from: directory).latestTrip)
        XCTAssertEqual(latest.routeSegments.map(\.count), [2, 1, 1])
        XCTAssertTrue(latest.hasRoute)
    }

    func test_naiveTimestampsAreIndiaLocalTime() throws {
        XCTAssertEqual(AnalyticsDate.parse("2026-10-05T08:00:00"), AnalyticsDate.parse("2026-10-05T02:30:00Z"))
        XCTAssertNil(AnalyticsDate.parse("unavailable"))
    }
}
