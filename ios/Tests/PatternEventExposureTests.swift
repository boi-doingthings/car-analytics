import XCTest
@testable import I20Logbook

final class PatternEventExposureTests: XCTestCase {
    private func trip(_ id: String, km: Double?, events: [Int]?, start: String? = "2026-10-05T08:00:00") -> NativeTrip {
        NativeTrip(record: OverviewTrip(id: id, start: start, km: km, events: events),
                   fuel: FuelTrip(id: id, km: 999), performance: nil, route: [])
    }

    func test_countsAndDistanceUseExactlyTheSameCompleteCohort() throws {
        let exposure = PatternEventExposure(trips: [
            trip("a", km: 20, events: [1, 2, 0]), trip("b", km: 80, events: [2, 0, 1]),
            trip("missing-events", km: 900, events: nil), trip("missing-distance", km: nil, events: [50, 50, 50]),
            trip("undated", km: 500, events: [99, 99, 99], start: nil)
        ])
        XCTAssertEqual(exposure.tripCount, 2)
        XCTAssertEqual(exposure.distanceKM, 100)
        XCTAssertEqual(exposure.byType.map(\.label), ["Harsh braking", "Rapid acceleration", "Overspeed alerts"])
        XCTAssertEqual(exposure.byType.map(\.count), [3, 2, 1])
        XCTAssertEqual(exposure.byType.map(\.rate), [30, 20, 10])
        XCTAssertTrue(exposure.byType.allSatisfy { $0.distanceKM == 100 && $0.tripCount == 2 })
        let monday = try XCTUnwrap(exposure.byWeekday.first)
        XCTAssertEqual(monday.count, 6)
        XCTAssertEqual(monday.rate, 60)
    }

    func test_knownZeroEventsHaveZeroRateButZeroDistanceHasUnknownRate() {
        let knownZero = PatternEventExposure(trips: [trip("zero-events", km: 10, events: [0, 0, 0])])
        XCTAssertEqual(knownZero.byType.map(\.rate), [0, 0, 0])
        XCTAssertEqual(knownZero.byWeekday.first?.rate, 0)
        let noExposure = PatternEventExposure(trips: [trip("parked", km: 0, events: [1, 0, 0])])
        XCTAssertEqual(noExposure.tripCount, 1)
        XCTAssertEqual(noExposure.distanceKM, 0)
        XCTAssertEqual(noExposure.byType.first?.count, 1)
        XCTAssertTrue(noExposure.byType.allSatisfy { $0.rate == nil })
        XCTAssertTrue(noExposure.byWeekday.allSatisfy { $0.rate == nil })
    }

    func test_invalidOrIncompleteDataIsExcludedWithoutInventingZeros() {
        let exposure = PatternEventExposure(trips: [
            trip("missing", km: 1, events: nil), trip("short", km: 1, events: [1, 2]),
            trip("long", km: 1, events: [1, 2, 3, 4]), trip("negative-event", km: 1, events: [0, -1, 0]),
            trip("negative-distance", km: -1, events: [0, 0, 0]), trip("nan", km: .nan, events: [0, 0, 0]),
            trip("infinite", km: .infinity, events: [0, 0, 0]), trip("bad-date", km: 10, events: [0, 0, 0], start: "invalid")
        ])
        XCTAssertEqual(exposure.tripCount, 0)
        XCTAssertNil(exposure.distanceKM)
        XCTAssertTrue(exposure.byType.allSatisfy { $0.rate == nil && $0.tripCount == 0 })
        XCTAssertTrue(exposure.byWeekday.allSatisfy { $0.rate == nil && $0.tripCount == 0 })
    }

    func test_weekdayUsesIndiaDateAndEachWeekdayOwnExposure() throws {
        let exposure = PatternEventExposure(trips: [
            trip("utc-sunday-ist-monday", km: 10, events: [1, 0, 0], start: "2026-10-04T20:00:00Z"),
            trip("sunday", km: 40, events: [0, 0, 2], start: "2026-10-04T08:00:00")
        ])
        XCTAssertEqual(exposure.byWeekday.map(\.label), ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"])
        XCTAssertEqual(exposure.byWeekday[0].rate, 100)
        XCTAssertEqual(exposure.byWeekday[0].distanceKM, 10)
        XCTAssertEqual(exposure.byWeekday[6].rate, 50)
        XCTAssertEqual(exposure.byWeekday[6].distanceKM, 40)
        XCTAssertNil(exposure.byWeekday[1].rate)
        XCTAssertEqual(exposure.byWeekday.reduce(0) { $0 + $1.tripCount }, exposure.tripCount)
        XCTAssertEqual(exposure.byWeekday.reduce(0) { $0 + $1.count }, exposure.byType.reduce(0) { $0 + $1.count })
    }
}
