import XCTest
@testable import I20Logbook

final class NativeAtlasSelectionTests: XCTestCase {
    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: Double(n) * 86_400) }
    func test_crossingEndThenMovingStartBackDoesNotRestoreAStaleEnd() {
        let bounds = day(0)...day(10)
        let crossed = NativeAtlasSelection.movingStart(to: day(8), in: day(2)...day(5), bounds: bounds)
        XCTAssertEqual(crossed, day(8)...day(8))
        XCTAssertEqual(NativeAtlasSelection.movingStart(to: day(2), in: crossed, bounds: bounds), day(2)...day(8))
        let reversed = NativeAtlasSelection.movingEnd(to: day(1), in: crossed, bounds: bounds)
        XCTAssertEqual(reversed, day(1)...day(1))
        XCTAssertEqual(NativeAtlasSelection.movingEnd(to: day(7), in: reversed, bounds: bounds), day(1)...day(7))
    }
    func test_archiveBoundsClampBothEndpoints() {
        let bounds = day(3)...day(6)
        XCTAssertEqual(NativeAtlasSelection.clamped(day(0)...day(10), to: bounds), bounds)
        XCTAssertEqual(NativeAtlasSelection.movingStart(to: day(9), in: bounds, bounds: bounds), day(6)...day(6))
        XCTAssertEqual(NativeAtlasSelection.movingEnd(to: day(1), in: bounds, bounds: bounds), day(3)...day(3))
    }
    func test_playbackNeverSpendsTicksOnAnUnchangedWholeTripCursor() {
        for count in [0, 1, 3, 49, 50, 51, 286, 800, 10_001] {
            let step = NativeAtlasSelection.playbackStep(tripCount: count)
            var cursor = 0, updates = 0
            while cursor < count {
                let next = min(count, cursor + step)
                XCTAssertGreaterThan(next, cursor)
                cursor = next
                updates += 1
            }
            XCTAssertEqual(cursor, count)
            XCTAssertLessThanOrEqual(updates, 50)
            if count > 0 {
                let duration = updates * NativeAtlasSelection.playbackIntervalMS(tripCount: count)
                XCTAssertGreaterThanOrEqual(duration, 5_000, "Small histories still need an inspectable replay")
                XCTAssertLessThanOrEqual(duration, 20_000)
            }
        }
    }
}
