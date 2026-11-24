import XCTest
import MapKit
@testable import I20Logbook

final class NativeJourneyRenderingTests: XCTestCase {
    private func trip(_ id: String = "t1", route: [[Double?]], routeAvailable: Bool = true) -> NativeTrip {
        NativeTrip(record: OverviewTrip(id: id, start: "2026-10-01T08:00:00", end: "2026-10-01T09:00:00",
                                         km: 30, drive: 50, idle: 10, route: routeAvailable),
                   fuel: nil, performance: nil, route: route)
    }

    func test_replayUsesEarlierActualSamplesAndNeverDifferentiatesAcrossGaps() {
        let source = trip(route: [[0, 0, 0, 0], [0, 0.001, 36, 10],
                                  [200, 0, 200, 20],
                                  [0, 0.002, 72, 30], [0, 0.003, 108, 40]])
        let data = NativeTripReplayData(trip: source)
        XCTAssertEqual(data.segments.count, 2)
        XCTAssertTrue(data.canPlay)
        XCTAssertEqual(data.sample(at: 25)?.seconds, 10)
        XCTAssertEqual(data.sample(at: 25)?.longitude, 0.001)
        XCTAssertEqual(data.samples[1].accelerationMS2 ?? -1, 1, accuracy: 1e-10)
        XCTAssertNil(data.samples[2].accelerationMS2, "A gap cannot become an acceleration observation")
        XCTAssertEqual(data.sample(at: 100)?.seconds, 40)
        XCTAssertNil(data.sample(at: .nan))
    }

    func test_routeWithoutTimesCannotPlayAndUnknownSpeedStaysUnknown() {
        let untimed = NativeTripReplayData(trip: trip(route: [[12, 77, nil, nil], [12.001, 77, nil, nil]]))
        XCTAssertFalse(untimed.canPlay)
        XCTAssertTrue(untimed.samples.isEmpty)
        XCTAssertEqual(untimed.segments.first?.count, 2, "A valid route can be mapped even without a replay clock")
        let speedMissing = NativeTripReplayData(trip: trip(route: [[0, 0, 10, 0], [0, 0.001, nil, 10], [0, 0.002, 30, 20]]))
        XCTAssertNil(speedMissing.samples[1].speedKMH)
        XCTAssertTrue(speedMissing.samples.allSatisfy { $0.accelerationMS2 == nil })
    }

    func test_densityCountsTripsRatherThanRepeatedSamplesAndSupportsTimelinePrefix() {
        let points: [[Double?]] = (0..<30).map { [0, Double($0) * 0.000001, 20, Double($0)] }
        let data = NativeAtlasRenderData.build(trips: [trip("a", route: points), trip("b", route: points)])
        XCTAssertEqual(data.density.count, 1)
        XCTAssertEqual(data.density[0].visits(through: 0), 0)
        XCTAssertEqual(data.density[0].visits(through: 1), 1)
        XCTAssertEqual(data.density[0].visits(through: 2), 2)
        XCTAssertEqual(data.pointCount, 60)
    }

    func test_largeHistoryGloballyBoundsOverlaysWithoutChangingSourceCounts() {
        let trips: [NativeTrip] = (0..<800).map { index in
            let latitude = Double(index % 100) * 0.003
            return trip("trip-\(index)", route: [[latitude, 0, 0, 0], [latitude, 0.001, 80, 10],
                                                [latitude, 0.002, 0, 20], [latitude, 0.003, 80, 30]])
        }
        let data = NativeAtlasRenderData.build(trips: trips)
        XCTAssertEqual(data.trips.count, 800)
        XCTAssertEqual(data.routedTripCount, 800)
        XCTAssertEqual(data.pointCount, 3200)
        XCTAssertEqual(data.sourceLineCount, 800)
        XCTAssertEqual(data.lines.count, NativeAtlasRenderData.lineBudget)
        XCTAssertGreaterThan(data.sourceSpeedLineCount, NativeAtlasRenderData.speedLineBudget)
        XCTAssertEqual(data.speedLines.count, NativeAtlasRenderData.speedLineBudget)
        XCTAssertLessThanOrEqual(data.density.count, NativeAtlasRenderData.densityBudget)
        XCTAssertTrue(data.lines.allSatisfy { $0.coordinates.count <= 160 })
        let repeated = NativeAtlasRenderData.build(trips: trips)
        XCTAssertEqual(data.lines.map(\.id), repeated.lines.map(\.id), "Display sampling must be deterministic")
    }

    func test_providerRouteAbsenceCannotBecomeAGeographicClaim() {
        let source = trip(route: [[0, 0, 0, 0], [0, 0.001, 20, 10]], routeAvailable: false)
        XCTAssertTrue(NativeTripReplayData(trip: source).segments.isEmpty)
        let atlas = NativeAtlasRenderData.build(trips: [source])
        XCTAssertEqual(atlas.trips.count, 1)
        XCTAssertEqual(atlas.routedTripCount, 0)
        XCTAssertTrue(atlas.lines.isEmpty)
        XCTAssertTrue(atlas.density.isEmpty)
    }

    func test_retainedGeometryIsPreparedOffMainAndReusedWithoutChangingSimplification() async throws {
        var route: [[Double?]] = (0..<250).map { [12, 77 + Double($0) * 0.00001, 30, Double($0)] }
        route.append([nil, nil, nil, nil])
        route += [[12.01, 77, 60, 300], [12.01, 77.001, 60, 310]]
        let source = trip(route: route)
        let result = await Task.detached { NativeAtlasRenderData.build(trips: [source]) }.value
        XCTAssertEqual(result.lines.count, 2, "An invalid source point must still break geometry")
        XCTAssertEqual(result.lines[0].coordinates.count, 160)
        XCTAssertEqual(result.lines[0].coordinates.first?.id, 0)
        XCTAssertEqual(result.lines[0].coordinates.last?.id, 249)
        for line in result.lines + result.speedLines {
            let geometry = line.polyline
            XCTAssertTrue(geometry === line.polyline, "Rendering must reuse the cached MapKit object")
            let copiedLine = line
            XCTAssertTrue(geometry === copiedLine.polyline, "Value copies must retain the same geometry")
            XCTAssertEqual(geometry.pointCount, line.coordinates.count)
            var coordinates = Array(repeating: CLLocationCoordinate2D(), count: geometry.pointCount)
            geometry.getCoordinates(&coordinates, range: NSRange(location: 0, length: geometry.pointCount))
            for (actual, expected) in zip(coordinates, line.coordinates) {
                XCTAssertEqual(actual.latitude, expected.latitude, accuracy: 1e-9)
                XCTAssertEqual(actual.longitude, expected.longitude, accuracy: 1e-9)
            }
        }
    }
}
