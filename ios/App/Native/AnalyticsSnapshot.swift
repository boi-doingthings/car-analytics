import Foundation

/// Typed, immutable read model for one published analytical generation. No archive writes occur here.
struct AnalyticsSnapshot: Sendable {
    /// Stable for this decoded value and distinct for every published cache generation.
    let generationID: String
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
                                     performance: optional(PerformanceAnalytics.self, "performance.json"),
                                     generationID: UUID(uuidString: directory.lastPathComponent) == nil
                                        ? UUID().uuidString : directory.lastPathComponent)
    }

    let trips: [NativeTrip]
    let history: DrivingHistory

    init(overview: OverviewAnalytics, fuel: FuelAnalytics? = nil, performance: PerformanceAnalytics? = nil,
         generationID: String = UUID().uuidString) {
        self.generationID = generationID
        self.overview = overview
        self.fuel = fuel
        self.performance = performance
        // Duplicate provider IDs are retained only once, with deterministic first-record precedence.
        let fuelByID = Dictionary((fuel?.trips ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let performanceByID = Dictionary((performance?.trips ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let normalizedTrips = overview.trips.filter { seen.insert($0.id).inserted }.map { trip in
            NativeTrip(record: trip, fuel: fuelByID[trip.id], performance: performanceByID[trip.id],
                       route: overview.routes[trip.id] ?? [])
        }.sorted {
            if $0.start == $1.start { return $0.id > $1.id }
            return ($0.start ?? .distantPast) > ($1.start ?? .distantPast)
        }
        self.trips = normalizedTrips
        self.history = DrivingHistory(trips: normalizedTrips)
    }

    /// An inclusive India-calendar date range; unknown timestamps are retained only for all-history.
    func tripRange(from: Date? = nil, through: Date? = nil) -> [NativeTrip] {
        if from == nil && through == nil { return trips }
        let calendar = AnalyticsDate.calendar
        let lower = from.map { calendar.startOfDay(for: $0) } ?? .distantPast
        let upper = through.flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) } ?? .distantFuture
        guard lower < upper else { return [] }
        return trips.filter { $0.start.map { $0 >= lower && $0 < upper } ?? false }
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
    let day: String
    let start: Date?
    let end: Date?
    init(record: OverviewTrip, fuel: FuelTrip?, performance: PerformanceTrip?, route: [[Double?]]) {
        self.record = record
        self.fuel = fuel
        self.performance = performance
        self.route = route
        let parsedStart = AnalyticsDate.parse(record.start)
        self.start = parsedStart
        self.day = parsedStart.map(AnalyticsDate.day) ?? String((record.start ?? "").prefix(10))
        self.end = AnalyticsDate.parse(record.end)
        let segments = Self.segmentRoute(route)
        self.routeSegments = segments
        self.coordinates = segments.flatMap { $0 }
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
    let coordinates: [RouteCoordinate]
    let routeSegments: [[RouteCoordinate]]
    var hardBrakeEvents: Int? { record.events.flatMap { $0.indices.contains(0) ? $0[0] : nil } }
    var rapidAccelerationEvents: Int? { record.events.flatMap { $0.indices.contains(1) ? $0[1] : nil } }
    var overspeedEvents: Int? { record.events.flatMap { $0.indices.contains(2) ? $0[2] : nil } }
    /// Do not draw an invented connection across invalid samples, large gaps or coordinate jumps.
    /// These conservative display cutoffs are quality guards, not proof of high-frequency telemetry.
    private static func segmentRoute(_ route: [[Double?]]) -> [[RouteCoordinate]] {
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
    static func day(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
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
    let days: [OverviewDay]?
    let months: [OverviewMonth]?
    let rhythm: [[Double?]]?
    let weekdayKM: [Double?]?
    let idleByHour: [HourlyIdle]?
    let places: [InferredPlace]?
    let hotspots: [TrafficHotspot]?
    let commute: OverviewCommute?
    let milestones: [OdometerMilestone]?
    let fuelHistory: [FuelGaugeReading]?
    let runningCost: RunningCost?
    let tank: TankHistory?
    let findings: [String: String?]?
    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at", vehicle, status, totals, trips, routes, service, services, reminders
        case days, months, rhythm, places, hotspots, commute, milestones, tank, findings
        case weekdayKM = "weekday_km", idleByHour = "idle_by_hour", fuelHistory = "fuel", runningCost = "running_cost"
    }
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
        days = try c.decodeIfPresent([OverviewDay].self, forKey: .days)
        months = try c.decodeIfPresent([OverviewMonth].self, forKey: .months)
        rhythm = try c.decodeIfPresent([[Double?]].self, forKey: .rhythm)
        weekdayKM = try c.decodeIfPresent([Double?].self, forKey: .weekdayKM)
        idleByHour = try c.decodeIfPresent([HourlyIdle].self, forKey: .idleByHour)
        places = try c.decodeIfPresent([InferredPlace].self, forKey: .places)
        hotspots = try c.decodeIfPresent([TrafficHotspot].self, forKey: .hotspots)
        commute = try c.decodeIfPresent(OverviewCommute.self, forKey: .commute)
        milestones = try c.decodeIfPresent([OdometerMilestone].self, forKey: .milestones)
        fuelHistory = try c.decodeIfPresent([FuelGaugeReading].self, forKey: .fuelHistory)
        runningCost = try c.decodeIfPresent(RunningCost.self, forKey: .runningCost)
        tank = try c.decodeIfPresent(TankHistory.self, forKey: .tank)
        findings = try c.decodeIfPresent([String: String?].self, forKey: .findings)
    }
}
