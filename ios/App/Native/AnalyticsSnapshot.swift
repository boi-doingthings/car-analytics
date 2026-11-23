import Foundation

/// Typed, immutable read model for one published analytical generation. No archive writes occur here.
struct AnalyticsSnapshot: Sendable {
    let overview: OverviewAnalytics
    let fuel: FuelAnalytics?
    let performance: PerformanceAnalytics?

    static func load(from directory: URL) throws -> AnalyticsSnapshot {
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
            try decoder.decode(type, from: Data(contentsOf: directory.appending(path: name)))
        }
        func optional<T: Decodable>(_ type: T.Type, _ name: String) throws -> T? {
            let file = directory.appending(path: name)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return try decode(type, name)
        }
        return try AnalyticsSnapshot(overview: decode(OverviewAnalytics.self, "data.json"),
                                     fuel: optional(FuelAnalytics.self, "fuel.json"),
                                     performance: optional(PerformanceAnalytics.self, "performance.json"))
    }

    let trips: [NativeTrip]

    init(overview: OverviewAnalytics, fuel: FuelAnalytics? = nil, performance: PerformanceAnalytics? = nil) {
        self.overview = overview
        self.fuel = fuel
        self.performance = performance
        // Duplicate provider IDs are retained only once, with deterministic first-record precedence.
        let fuelByID = Dictionary((fuel?.trips ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let performanceByID = Dictionary((performance?.trips ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        self.trips = overview.trips.filter { seen.insert($0.id).inserted }.map { trip in
            NativeTrip(record: trip, fuel: fuelByID[trip.id], performance: performanceByID[trip.id],
                       route: overview.routes[trip.id] ?? [])
        }.sorted {
            if $0.start == $1.start { return $0.id > $1.id }
            return ($0.start ?? .distantPast) > ($1.start ?? .distantPast)
        }
    }

    var latestTrip: NativeTrip? { trips.first }
    /// Source observation age, deliberately independent of the analytical rebuild timestamp.
    var latestObservationDate: Date? {
        [overview.status?.asOf, latestTrip?.end, latestTrip?.start].compactMap { $0 }.max()
    }

    func periodSummary(days: Int, endingOn anchor: Date = Date()) -> PeriodSummary {
        let count = max(days, 1)
        let calendar = AnalyticsDate.calendar
        let endDay = calendar.startOfDay(for: anchor)
        let start = calendar.date(byAdding: .day, value: -(count - 1), to: endDay)!
        let end = calendar.date(byAdding: .day, value: 1, to: endDay)!
        let selected = trips.filter { trip in
            guard let date = trip.start else { return false }
            return date >= start && date < end && date <= anchor
        }
        let grouped = Dictionary(grouping: selected, by: \.day)
        let daily = grouped.keys.sorted().compactMap { day -> DailyDistance? in
            guard let date = AnalyticsDate.parse(day) else { return nil }
            return DailyDistance(day: day, date: date, distanceKM: Self.completeSum(grouped[day]!.map(\.distanceKM)))
        }
        let drive = Self.completeSum(selected.map(\.driveMinutes))
        let idle = Self.completeSum(selected.map(\.idleMinutes))
        let share: Double? = drive.flatMap { moving in idle.flatMap { standing in
            moving + standing > 0 ? standing / (moving + standing) : nil
        } }
        return PeriodSummary(days: count, start: start, end: anchor, tripCount: selected.count,
                             distanceKM: Self.completeSum(selected.map(\.distanceKM)),
                             elapsedMinutes: Self.completeSum(selected.map(\.elapsedMinutes)),
                             idleMinutes: idle, idleShare: share,
                             estimatedFuelCost: Self.completeSum(selected.map(\.estimatedFuelCost)),
                             fuelCostTripCount: selected.filter { $0.estimatedFuelCost != nil }.count,
                             distanceTripCount: selected.filter { $0.distanceKM != nil }.count, daily: daily)
    }

    /// A descriptive historical comparison. Place names are inferred labels, not verified route identity.
    func compare(_ trip: NativeTrip) -> JourneyComparison {
        guard let origin = trip.origin, let destination = trip.destination,
              !origin.isEmpty, !destination.isEmpty, origin != destination,
              let start = trip.start, let distance = trip.distanceKM, distance > 0 else {
            return JourneyComparison(cohort: [], medianMinutes: nil, lowerQuartileMinutes: nil,
                                     upperQuartileMinutes: nil, differenceMinutes: nil,
                                     reason: "This trip needs known endpoints, departure time and distance before it can be compared.")
        }
        let calendar = AnalyticsDate.calendar
        let minute = calendar.component(.hour, from: start) * 60 + calendar.component(.minute, from: start)
        let cohort = trips.filter { candidate in
            guard candidate.id != trip.id, candidate.origin == origin, candidate.destination == destination,
                  let date = candidate.start, date < start, let km = candidate.distanceKM,
                  km >= distance * 0.8, km <= distance * 1.2,
                  let elapsed = candidate.elapsedMinutes, elapsed > 0,
                  calendar.isDateInWeekend(date) == calendar.isDateInWeekend(start) else { return false }
            let other = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
            let gap = abs(minute - other)
            return min(gap, 1440 - gap) <= 90
        }
        let dates = Set(cohort.map(\.day)).count
        guard cohort.count >= 10, dates >= 3 else {
            return JourneyComparison(cohort: cohort, medianMinutes: nil, lowerQuartileMinutes: nil,
                                     upperQuartileMinutes: nil, differenceMinutes: nil,
                                     reason: "Needs at least 10 earlier comparable trips across 3 dates. Found \(cohort.count) trips across \(dates) dates.")
        }
        let durations = cohort.compactMap(\.elapsedMinutes).sorted()
        let median = Self.quantile(durations, 0.5)
        return JourneyComparison(cohort: cohort, medianMinutes: median,
                                 lowerQuartileMinutes: Self.quantile(durations, 0.25),
                                 upperQuartileMinutes: Self.quantile(durations, 0.75),
                                 differenceMinutes: trip.elapsedMinutes.map { $0 - median }, reason: nil)
    }

    private static func completeSum(_ values: [Double?]) -> Double? {
        guard !values.isEmpty, values.allSatisfy({ $0 != nil && $0!.isFinite }) else { return nil }
        return values.reduce(0) { $0 + $1! }
    }
    private static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        let position = Double(sorted.count - 1) * q
        let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }
}

struct PeriodSummary: Sendable {
    let days: Int
    let start: Date
    let end: Date
    let tripCount: Int
    let distanceKM: Double?
    let elapsedMinutes: Double?
    let idleMinutes: Double?
    let idleShare: Double?
    let estimatedFuelCost: Double?
    let fuelCostTripCount: Int
    let distanceTripCount: Int
    /// Only days with archived trips are represented. Missing archive days are not invented as zero.
    let daily: [DailyDistance]
}

struct DailyDistance: Identifiable, Sendable {
    var id: String { day }
    let day: String
    let date: Date
    let distanceKM: Double?
}

struct JourneyComparison: Sendable {
    let cohort: [NativeTrip]
    let medianMinutes: Double?
    let lowerQuartileMinutes: Double?
    let upperQuartileMinutes: Double?
    let differenceMinutes: Double?
    let reason: String?
    var isSupported: Bool { reason == nil }
    var tripCount: Int { cohort.count }
    var dateCount: Int { Set(cohort.map(\.day)).count }
    let method = "Earlier trips with the same inferred endpoints and direction, distance within 20%, departure within 90 minutes, and the same weekday/weekend category. Traffic and weather are not controlled."
}

struct RouteCoordinate: Sendable, Identifiable {
    let id: Int
    let latitude: Double
    let longitude: Double
    let elapsedSeconds: Double?
    let estimatedSpeedKMH: Double?
}

struct NativeTrip: Identifiable, Sendable {
    let record: OverviewTrip
    let fuel: FuelTrip?
    let performance: PerformanceTrip?
    let route: [[Double?]]
    var id: String { record.id }
    var startText: String { record.start ?? "" }
    var day: String { String(startText.prefix(10)) }
    let start: Date?
    let end: Date?
    init(record: OverviewTrip, fuel: FuelTrip?, performance: PerformanceTrip?, route: [[Double?]]) {
        self.record = record
        self.fuel = fuel
        self.performance = performance
        self.route = route
        self.start = AnalyticsDate.parse(record.start)
        self.end = AnalyticsDate.parse(record.end)
    }
    /// Raw provider trip distance; corrected model distance is exposed separately.
    var distanceKM: Double? { record.km }
    var correctedDistanceKM: Double? { fuel?.km ?? performance?.km }
    var driveMinutes: Double? { record.drive }
    var idleMinutes: Double? { record.idle }
    var engineMinutes: Double? {
        guard let drive = driveMinutes, let idle = idleMinutes else { return nil }
        return drive + idle
    }
    var elapsedMinutes: Double? {
        if let start, let end, end >= start { return end.timeIntervalSince(start) / 60 }
        return performance?.elapsedMinutes ?? engineMinutes
    }
    var idleShare: Double? {
        guard let idle = idleMinutes, let engine = engineMinutes, engine > 0 else { return nil }
        return idle / engine
    }
    var movingSpeedKMH: Double? { record.avg }
    var maxSpeedKMH: Double? { record.max }
    var origin: String? { record.from }
    var destination: String? { record.to }
    var title: String { "\(origin ?? "Unknown start") → \(destination ?? "Unknown destination")" }
    var estimatedFuelLitres: Double? { fuel?.estimatedLitres }
    var estimatedFuelCost: Double? { fuel?.cost }
    var events: Int? { record.events.map { $0.reduce(0, +) } }
    var hasRoute: Bool { record.route == true && routeSegments.contains { $0.count >= 2 } }
    var coordinates: [RouteCoordinate] { routeSegments.flatMap { $0 } }
    /// Do not draw an invented connection across invalid samples, large gaps or coordinate jumps.
    /// These conservative display cutoffs are quality guards, not proof of high-frequency telemetry.
    var routeSegments: [[RouteCoordinate]] {
        var segments: [[RouteCoordinate]] = []
        var current: [RouteCoordinate] = []
        func flush() {
            if !current.isEmpty { segments.append(current); current = [] }
        }
        for (index, point) in route.enumerated() {
            guard point.count >= 2, let latitude = point[0], let longitude = point[1],
                  latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                flush()
                continue
            }
            let next = RouteCoordinate(id: index, latitude: latitude, longitude: longitude,
                                       elapsedSeconds: point.count > 3 ? point[3] : nil,
                                       estimatedSpeedKMH: point.count > 2 ? point[2] : nil)
            if let previous = current.last {
                let timeBreak: Bool
                if let before = previous.elapsedSeconds, let after = next.elapsedSeconds {
                    timeBreak = after <= before || after - before > 120
                } else { timeBreak = false }
                let radians = Double.pi / 180
                let dLat = (next.latitude - previous.latitude) * radians
                let dLon = (next.longitude - previous.longitude) * radians
                let a = pow(sin(dLat / 2), 2) + cos(previous.latitude * radians) * cos(next.latitude * radians) * pow(sin(dLon / 2), 2)
                let distanceKM = 6371 * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
                if timeBreak || distanceKM > 2 { flush() }
            }
            current.append(next)
        }
        flush()
        return segments
    }
}

enum AnalyticsDate {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }
    /// Provider timestamps without offsets are India local time, even when the phone travels.
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.isLenient = false
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

struct OverviewAnalytics: Decodable, Sendable {
    let generatedAt: String?
    let vehicle: VehicleSummary?
    let status: VehicleStatus?
    let totals: OverviewTotals?
    let trips: [OverviewTrip]
    let routes: [String: [[Double?]]]
    let service: [ServiceDue]
    let services: [ServiceVisitSummary]
    let reminders: [MaintenanceReminder]
    enum CodingKeys: String, CodingKey { case generatedAt = "generated_at", vehicle, status, totals, trips, routes, service, services, reminders }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try c.decodeIfPresent(String.self, forKey: .generatedAt)
        vehicle = try c.decodeIfPresent(VehicleSummary.self, forKey: .vehicle)
        status = try c.decodeIfPresent(VehicleStatus.self, forKey: .status)
        totals = try c.decodeIfPresent(OverviewTotals.self, forKey: .totals)
        trips = try c.decodeIfPresent([OverviewTrip].self, forKey: .trips) ?? []
        routes = try c.decodeIfPresent([String: [[Double?]]].self, forKey: .routes) ?? [:]
        service = try c.decodeIfPresent([ServiceDue].self, forKey: .service) ?? []
        services = try c.decodeIfPresent([ServiceVisitSummary].self, forKey: .services) ?? []
        reminders = try c.decodeIfPresent([MaintenanceReminder].self, forKey: .reminders) ?? []
    }
}
struct VehicleSummary: Decodable, Sendable { let model: String?; let year: String? }
struct VehicleStatus: Decodable, Sendable {
    let odometer: Double?
    let fuelPercent: Double?
    let rangeKM: Double?
    let locked: Bool?
    let lowFuel: Bool?
    let asOfText: String?
    var asOf: Date? { AnalyticsDate.parse(asOfText) }
    enum CodingKeys: String, CodingKey { case odometer, locked; case fuelPercent = "fuel_pct", rangeKM = "range_km", lowFuel = "low_fuel", asOfText = "as_of" }
}
struct OverviewTotals: Decodable, Sendable {
    let km: Double?
    let trips: Int?
    let hours: Double?
    let idleShare: Double?
    let coverage: Double?
    let routedTrips: Int?
    let firstDay: String?
    let lastDay: String?
    enum CodingKeys: String, CodingKey { case km, trips, hours, coverage; case idleShare = "idle_share", routedTrips = "routed_trips", firstDay = "first_day", lastDay = "last_day" }
}
struct OverviewTrip: Decodable, Sendable {
    let id: String
    let start: String?
    let end: String?
    let km: Double?
    let drive: Double?
    let idle: Double?
    let avg: Double?
    let max: Double?
    let events: [Int]?
    let route: Bool?
    let from: String?
    let to: String?
}
struct ServiceDue: Decodable, Identifiable, Sendable {
    var id: String { item }
    let item: String
    let due: String?
    let daysLeft: Int?
    let kmDue: Double?
    let trigger: String?
    let lastDone: LastService?
    enum CodingKeys: String, CodingKey { case item, due, trigger; case daysLeft = "days_left", kmDue = "km_due", lastDone = "last_done" }
    struct LastService: Decodable, Sendable { let date: String?; let km: Double? }
}
struct ServiceVisitSummary: Decodable, Identifiable, Sendable {
    let id: String?
    let date: String?
    let workshop: String?
    let total: Double?
}
struct MaintenanceReminder: Decodable, Identifiable, Sendable {
    var id: String { "\(date ?? "")-\(category ?? "")-\(note ?? "")" }
    let date: String?
    let category: String?
    let note: String?
    let daysLeft: Int?
    enum CodingKeys: String, CodingKey { case date, category, note; case daysLeft = "days_left" }
}

struct FuelAnalytics: Decodable, Sendable {
    let totals: FuelTotals?
    let model: FuelModel?
    let calibration: FuelCalibration?
    let trips: [FuelTrip]?
    let intervals: [FuelInterval]?
}
struct FuelTotals: Decodable, Sendable {
    let fills: Int?
    let spend: Double?
    let litres: Double?
    let economyKMPL: Double?
    let modelCostPerKM: Double?
    let missingFills: Int?
    let firstFill: String?
    let lastFill: String?
    enum CodingKeys: String, CodingKey { case fills, spend, litres; case economyKMPL = "kmpl_valid", modelCostPerKM = "rs_per_km_model", missingFills = "missing_fills", firstFill = "first_fill", lastFill = "last_fill" }
}
struct FuelModel: Decodable, Sendable {
    let coef: FuelCoefficients?
    let sd: FuelCoefficients?
    let intervalCount: Int?
    let leaveOneOutMAE: Double?
    let baselineMAE: Double?
    let validation: FuelValidation?
    enum CodingKeys: String, CodingKey { case coef, sd, validation; case intervalCount = "n_intervals", leaveOneOutMAE = "loo_mae", baselineMAE = "naive_loo_mae" }
}
/// Consumption-model diagnostics conditional on the currently reconstructed refuel intervals.
struct FuelValidation: Decodable, Sendable {
    let schema: Int
    let units: String
    let scope: String
    let loo: FuelValidationResult
    let chronological: FuelValidationResult
}
struct FuelValidationResult: Decodable, Sendable {
    let method: String
    let minTrainIntervals: Int
    let predictions: Int
    let modelMAE: Double?
    let baselineMAE: Double?
    let modelBias: Double?
    enum CodingKeys: String, CodingKey {
        case method
        case minTrainIntervals = "min_train_intervals"
        case predictions = "n_predictions"
        case modelMAE = "model_mae_l"
        case baselineMAE = "baseline_mae_l"
        case modelBias = "model_bias_l"
    }
}
struct FuelCoefficients: Decodable, Sendable {
    let cityL100: Double?
    let highwayL100: Double?
    let idleLPH: Double?
    enum CodingKeys: String, CodingKey { case cityL100 = "city_l100", highwayL100 = "hwy_l100", idleLPH = "idle_lph" }
}
struct FuelCalibration: Decodable, Sendable {
    let delta: Double?
    let n: Int?
    let residualSD: Double?
    enum CodingKeys: String, CodingKey { case delta, n; case residualSD = "resid_sd" }
}
struct FuelInterval: Decodable, Identifiable, Sendable {
    var id: String { "\(from ?? "")-\(to ?? "")" }
    let from: String?
    let to: String?
    let km: Double?
    let litres: Double?
    let kmpl: Double?
    let status: String?
}
struct FuelTrip: Decodable, Sendable {
    let id: String
    let km: Double?
    let estimatedLitres: Double?
    let cost: Double?
    enum CodingKeys: String, CodingKey { case id, km, cost; case estimatedLitres = "est_l" }
}
struct PerformanceAnalytics: Decodable, Sendable { let trips: [PerformanceTrip]? }
struct PerformanceTrip: Decodable, Sendable {
    let id: String
    let km: Double?
    let elapsedMinutes: Double?
    enum CodingKeys: String, CodingKey { case id = "trip_id", km, elapsedMinutes = "elapsed_min" }
}
