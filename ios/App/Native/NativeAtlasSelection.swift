import Foundation

/// Deterministic rules for staged Atlas filters and whole-drive playback.
enum NativeAtlasSelection {
    static func clamped(_ range: ClosedRange<Date>, to bounds: ClosedRange<Date>) -> ClosedRange<Date> {
        let start = max(bounds.lowerBound, min(bounds.upperBound, range.lowerBound))
        return start...max(start, min(bounds.upperBound, range.upperBound))
    }
    static func movingStart(to value: Date, in range: ClosedRange<Date>, bounds: ClosedRange<Date>) -> ClosedRange<Date> {
        let start = max(bounds.lowerBound, min(bounds.upperBound, value))
        return clamped(start...max(start, range.upperBound), to: bounds)
    }
    static func movingEnd(to value: Date, in range: ClosedRange<Date>, bounds: ClosedRange<Date>) -> ClosedRange<Date> {
        let end = max(bounds.lowerBound, min(bounds.upperBound, value))
        return clamped(min(range.lowerBound, end)...end, to: bounds)
    }
    static func playbackIntervalMS(tripCount: Int) -> Int {
        max(400, 6_000 / max(1, min(50, tripCount - 1)))
    }

    /// At most fifty updates, each revealing at least one whole archived drive.
    static func playbackStep(tripCount: Int) -> Int {
        max(1, Int(ceil(Double(max(0, tripCount)) / 50)))
    }
}
