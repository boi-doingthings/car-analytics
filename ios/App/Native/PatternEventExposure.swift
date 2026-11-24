import Foundation

/// Provider event rates share one complete cohort for both event counts and recorded distance.
/// Distance is the raw trip measurement, not an estimated or calibrated fuel-model distance.
struct PatternEventExposure: Sendable {
    let byType: [PatternExposureRate]
    let byWeekday: [PatternExposureRate]
    let tripCount: Int
    let distanceKM: Double?

    init(trips: [NativeTrip]) {
        let cohort = trips.compactMap { trip -> (weekday: Int, km: Double, counts: [Double])? in
            guard let date = trip.start, date.timeIntervalSince1970.isFinite,
                  let km = trip.distanceKM, km.isFinite, km >= 0,
                  let counts = trip.record.events, counts.count == 3,
                  counts.allSatisfy({ $0 >= 0 }) else { return nil }
            return ((AnalyticsDate.calendar.component(.weekday, from: date) + 5) % 7,
                    km, counts.map(Double.init))
        }
        tripCount = cohort.count
        let totalKM = cohort.reduce(0.0) { $0 + $1.km }
        distanceKM = cohort.isEmpty || !totalKM.isFinite ? nil : totalKM

        byType = ["Harsh braking", "Rapid acceleration", "Overspeed alerts"].enumerated().map { index, label in
            PatternExposureRate(label: label, count: cohort.reduce(0.0) { $0 + $1.counts[index] },
                                tripCount: cohort.count, distanceKM: totalKM)
        }
        byWeekday = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"].enumerated().map { index, label in
            let group = cohort.filter { $0.weekday == index }
            return PatternExposureRate(label: label,
                                       count: group.reduce(0.0) { $0 + $1.counts.reduce(0, +) },
                                       tripCount: group.count,
                                       distanceKM: group.reduce(0.0) { $0 + $1.km })
        }
    }
}

struct PatternExposureRate: Identifiable, Sendable {
    var id: String { label }
    let label: String
    /// Events per 1,000 recorded kilometres; nil means no positive usable exposure.
    let rate: Double?
    let count: Double
    let tripCount: Int
    let distanceKM: Double

    init(label: String, count: Double, tripCount: Int, distanceKM: Double) {
        self.label = label
        self.count = count
        self.tripCount = tripCount
        self.distanceKM = distanceKM
        let candidate = count / distanceKM * 1_000
        rate = distanceKM > 0 && distanceKM.isFinite && count.isFinite && candidate.isFinite ? candidate : nil
    }
}
