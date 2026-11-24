import Foundation

// Saved analytical contracts. Optional values and missing datasets remain distinct from zero.

struct VehicleSummary: Decodable, Sendable {
    let model: String?
    let year: String?
    let registrationDate: String?
    enum CodingKeys: String, CodingKey {
        case model
        case year
        case registrationDate = "reg_date"
    }
    init(model: String? = nil, year: String? = nil, registrationDate: String? = nil) {
        self.model = model
        self.year = year
        self.registrationDate = registrationDate
    }
}

struct VehicleStatus: Decodable, Sendable {
    let odometer: Double?
    let fuelPercent: Double?
    let rangeKM: Double?
    let locked: Bool?
    let lowFuel: Bool?
    let asOfText: String?
    let fuelLitres: Double?
    let park: [Double?]?
    enum CodingKeys: String, CodingKey {
        case odometer
        case fuelPercent = "fuel_pct"
        case rangeKM = "range_km"
        case locked
        case lowFuel = "low_fuel"
        case asOfText = "as_of"
        case fuelLitres = "fuel_l"
        case park
    }
    init(odometer: Double? = nil, fuelPercent: Double? = nil, rangeKM: Double? = nil, locked: Bool? = nil, lowFuel: Bool? = nil, asOfText: String? = nil, fuelLitres: Double? = nil, park: [Double?]? = nil) {
        self.odometer = odometer
        self.fuelPercent = fuelPercent
        self.rangeKM = rangeKM
        self.locked = locked
        self.lowFuel = lowFuel
        self.asOfText = asOfText
        self.fuelLitres = fuelLitres
        self.park = park
    }
    var asOf: Date? { AnalyticsDate.parse(asOfText) }
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
    let daysDriven: Int?
    let idleHours: Double?
    let movingSpeedKMH: Double?
    let topSpeedKMH: Double?
    let pace90d: Double?
    let shortShare: Double?
    let hardBrake: Int?
    let rapidAccel: Int?
    let overspeed: Int?
    enum CodingKeys: String, CodingKey {
        case km
        case trips
        case hours
        case idleShare = "idle_share"
        case coverage
        case routedTrips = "routed_trips"
        case firstDay = "first_day"
        case lastDay = "last_day"
        case daysDriven = "days_driven"
        case idleHours = "idle_hours"
        case movingSpeedKMH = "moving_kmh"
        case topSpeedKMH = "top_kmh"
        case pace90d = "pace_90d"
        case shortShare = "short_share"
        case hardBrake = "hard_brake"
        case rapidAccel = "rapid_accel"
        case overspeed
    }
    init(km: Double? = nil, trips: Int? = nil, hours: Double? = nil, idleShare: Double? = nil, coverage: Double? = nil, routedTrips: Int? = nil, firstDay: String? = nil, lastDay: String? = nil, daysDriven: Int? = nil, idleHours: Double? = nil, movingSpeedKMH: Double? = nil, topSpeedKMH: Double? = nil, pace90d: Double? = nil, shortShare: Double? = nil, hardBrake: Int? = nil, rapidAccel: Int? = nil, overspeed: Int? = nil) {
        self.km = km
        self.trips = trips
        self.hours = hours
        self.idleShare = idleShare
        self.coverage = coverage
        self.routedTrips = routedTrips
        self.firstDay = firstDay
        self.lastDay = lastDay
        self.daysDriven = daysDriven
        self.idleHours = idleHours
        self.movingSpeedKMH = movingSpeedKMH
        self.topSpeedKMH = topSpeedKMH
        self.pace90d = pace90d
        self.shortShare = shortShare
        self.hardBrake = hardBrake
        self.rapidAccel = rapidAccel
        self.overspeed = overspeed
    }
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
    enum CodingKeys: String, CodingKey {
        case id
        case start
        case end
        case km
        case drive
        case idle
        case avg
        case max
        case events
        case route
        case from
        case to
    }
    init(id: String, start: String? = nil, end: String? = nil, km: Double? = nil, drive: Double? = nil, idle: Double? = nil, avg: Double? = nil, max: Double? = nil, events: [Int]? = nil, route: Bool? = nil, from: String? = nil, to: String? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.km = km
        self.drive = drive
        self.idle = idle
        self.avg = avg
        self.max = max
        self.events = events
        self.route = route
        self.from = from
        self.to = to
    }
}

struct ServiceDue: Decodable, Identifiable, Sendable {
    var id: String { item }
    let item: String
    let due: String?
    let daysLeft: Int?
    let kmDue: Double?
    let trigger: String?
    let lastDone: LastService?
    let everyKM: Double?
    let everyMonths: Int?
    enum CodingKeys: String, CodingKey {
        case item
        case due
        case daysLeft = "days_left"
        case kmDue = "km_due"
        case trigger
        case lastDone = "last_done"
        case everyKM = "every_km"
        case everyMonths = "every_months"
    }
    init(item: String, due: String? = nil, daysLeft: Int? = nil, kmDue: Double? = nil, trigger: String? = nil, lastDone: LastService? = nil, everyKM: Double? = nil, everyMonths: Int? = nil) {
        self.item = item
        self.due = due
        self.daysLeft = daysLeft
        self.kmDue = kmDue
        self.trigger = trigger
        self.lastDone = lastDone
        self.everyKM = everyKM
        self.everyMonths = everyMonths
    }
    struct LastService: Decodable, Sendable { let date: String?; let km: Double? }
}

struct ServiceVisitSummary: Decodable, Identifiable, Sendable {
    let id: String?
    let date: String?
    let workshop: String?
    let total: Double?
    let odometerKM: Double?
    let kind: String?
    let invoice: String?
    let notes: String?
    enum CodingKeys: String, CodingKey {
        case id
        case date
        case workshop
        case total
        case odometerKM = "odometer_km"
        case kind
        case invoice
        case notes
    }
    init(id: String? = nil, date: String? = nil, workshop: String? = nil, total: Double? = nil, odometerKM: Double? = nil, kind: String? = nil, invoice: String? = nil, notes: String? = nil) {
        self.id = id
        self.date = date
        self.workshop = workshop
        self.total = total
        self.odometerKM = odometerKM
        self.kind = kind
        self.invoice = invoice
        self.notes = notes
    }
}

struct MaintenanceReminder: Decodable, Identifiable, Sendable {
    var id: String { "\(date ?? "")-\(category ?? "")-\(note ?? "")" }
    let date: String?
    let category: String?
    let note: String?
    let daysLeft: Int?
    enum CodingKeys: String, CodingKey {
        case date
        case category
        case note
        case daysLeft = "days_left"
    }
    init(date: String? = nil, category: String? = nil, note: String? = nil, daysLeft: Int? = nil) {
        self.date = date
        self.category = category
        self.note = note
        self.daysLeft = daysLeft
    }
}

struct FuelAnalytics: Decodable, Sendable {
    let totals: FuelTotals?
    let model: FuelModel?
    let calibration: FuelCalibration?
    let trips: [FuelTrip]?
    let intervals: [FuelInterval]?
    let source: String?
    let constants: FuelConstants?
    let fills: [FuelFill]?
    let monthly: [FuelMonth]?
    let brands: [FuelBrand]?
    let missing: [MissingFuelInterval]?
    let fuelLevel: [FuelGaugeReading]?
    let tank: TankHistory?
    enum CodingKeys: String, CodingKey {
        case totals
        case model
        case calibration
        case trips
        case intervals
        case source
        case constants
        case fills
        case monthly
        case brands
        case missing
        case fuelLevel = "fuel_level"
        case tank
    }
    init(totals: FuelTotals? = nil, model: FuelModel? = nil, calibration: FuelCalibration? = nil, trips: [FuelTrip]? = nil, intervals: [FuelInterval]? = nil, source: String? = nil, constants: FuelConstants? = nil, fills: [FuelFill]? = nil, monthly: [FuelMonth]? = nil, brands: [FuelBrand]? = nil, missing: [MissingFuelInterval]? = nil, fuelLevel: [FuelGaugeReading]? = nil, tank: TankHistory? = nil) {
        self.totals = totals
        self.model = model
        self.calibration = calibration
        self.trips = trips
        self.intervals = intervals
        self.source = source
        self.constants = constants
        self.fills = fills
        self.monthly = monthly
        self.brands = brands
        self.missing = missing
        self.fuelLevel = fuelLevel
        self.tank = tank
    }
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
    let averageRate: Double?
    let validKM: Double?
    let idleLitres: Double?
    let idleCost: Double?
    let idleFuelShare: Double?
    let estimatedLitres: Double?
    let estimatedCost: Double?
    let cityDistanceShare: Double?
    let cityFuelShare: Double?
    let premiumFills: Int?
    let premiumExtra: Double?
    let unloggedLitres: Double?
    let overTank: Int?
    let odometerSpan: [Double?]?
    enum CodingKeys: String, CodingKey {
        case fills
        case spend
        case litres
        case economyKMPL = "kmpl_valid"
        case modelCostPerKM = "rs_per_km_model"
        case missingFills = "missing_fills"
        case firstFill = "first_fill"
        case lastFill = "last_fill"
        case averageRate = "avg_rate"
        case validKM = "km_valid"
        case idleLitres = "idle_l"
        case idleCost = "idle_cost"
        case idleFuelShare = "idle_share_of_fuel"
        case estimatedLitres = "est_l_total"
        case estimatedCost = "est_cost_total"
        case cityDistanceShare = "city_share_km"
        case cityFuelShare = "city_share_fuel"
        case premiumFills = "premium_fills"
        case premiumExtra = "premium_extra"
        case unloggedLitres = "unlogged_l"
        case overTank = "over_tank"
        case odometerSpan = "odo_span"
    }
    init(fills: Int? = nil, spend: Double? = nil, litres: Double? = nil, economyKMPL: Double? = nil, modelCostPerKM: Double? = nil, missingFills: Int? = nil, firstFill: String? = nil, lastFill: String? = nil, averageRate: Double? = nil, validKM: Double? = nil, idleLitres: Double? = nil, idleCost: Double? = nil, idleFuelShare: Double? = nil, estimatedLitres: Double? = nil, estimatedCost: Double? = nil, cityDistanceShare: Double? = nil, cityFuelShare: Double? = nil, premiumFills: Int? = nil, premiumExtra: Double? = nil, unloggedLitres: Double? = nil, overTank: Int? = nil, odometerSpan: [Double?]? = nil) {
        self.fills = fills
        self.spend = spend
        self.litres = litres
        self.economyKMPL = economyKMPL
        self.modelCostPerKM = modelCostPerKM
        self.missingFills = missingFills
        self.firstFill = firstFill
        self.lastFill = lastFill
        self.averageRate = averageRate
        self.validKM = validKM
        self.idleLitres = idleLitres
        self.idleCost = idleCost
        self.idleFuelShare = idleFuelShare
        self.estimatedLitres = estimatedLitres
        self.estimatedCost = estimatedCost
        self.cityDistanceShare = cityDistanceShare
        self.cityFuelShare = cityFuelShare
        self.premiumFills = premiumFills
        self.premiumExtra = premiumExtra
        self.unloggedLitres = unloggedLitres
        self.overTank = overTank
        self.odometerSpan = odometerSpan
    }
}

struct FuelModel: Decodable, Sendable {
    let coef: FuelCoefficients?
    let sd: FuelCoefficients?
    let intervalCount: Int?
    let leaveOneOutMAE: Double?
    let baselineMAE: Double?
    let validation: FuelValidation?
    let prior: [String: GaussianPrior]?
    let posteriorCorrelation: [[Double?]]?
    let sigmaLitres: Double?
    let r2: Double?
    let cityKMPL: Double?
    let highwayKMPL: Double?
    let curves: [String: DensityCurve]?
    let evidence: NoiseEvidence?
    let fitted: [FuelFitPoint]?
    enum CodingKeys: String, CodingKey {
        case coef
        case sd
        case intervalCount = "n_intervals"
        case leaveOneOutMAE = "loo_mae"
        case baselineMAE = "naive_loo_mae"
        case validation
        case prior
        case posteriorCorrelation = "posterior_corr"
        case sigmaLitres = "sigma_l"
        case r2
        case cityKMPL = "kmpl_city"
        case highwayKMPL = "kmpl_hwy"
        case curves
        case evidence
        case fitted
    }
    init(coef: FuelCoefficients? = nil, sd: FuelCoefficients? = nil, intervalCount: Int? = nil, leaveOneOutMAE: Double? = nil, baselineMAE: Double? = nil, validation: FuelValidation? = nil, prior: [String: GaussianPrior]? = nil, posteriorCorrelation: [[Double?]]? = nil, sigmaLitres: Double? = nil, r2: Double? = nil, cityKMPL: Double? = nil, highwayKMPL: Double? = nil, curves: [String: DensityCurve]? = nil, evidence: NoiseEvidence? = nil, fitted: [FuelFitPoint]? = nil) {
        self.coef = coef
        self.sd = sd
        self.intervalCount = intervalCount
        self.leaveOneOutMAE = leaveOneOutMAE
        self.baselineMAE = baselineMAE
        self.validation = validation
        self.prior = prior
        self.posteriorCorrelation = posteriorCorrelation
        self.sigmaLitres = sigmaLitres
        self.r2 = r2
        self.cityKMPL = cityKMPL
        self.highwayKMPL = highwayKMPL
        self.curves = curves
        self.evidence = evidence
        self.fitted = fitted
    }
}

struct FuelValidation: Decodable, Sendable {
    let schema: Int
    let units: String
    let scope: String
    let loo: FuelValidationResult
    let chronological: FuelValidationResult
    let caveat: String?
    let biasDefinition: String?
    enum CodingKeys: String, CodingKey {
        case schema
        case units
        case scope
        case loo
        case chronological
        case caveat
        case biasDefinition = "bias_definition"
    }
    init(schema: Int, units: String, scope: String, loo: FuelValidationResult, chronological: FuelValidationResult, caveat: String? = nil, biasDefinition: String? = nil) {
        self.schema = schema
        self.units = units
        self.scope = scope
        self.loo = loo
        self.chronological = chronological
        self.caveat = caveat
        self.biasDefinition = biasDefinition
    }
}

struct FuelValidationResult: Decodable, Sendable {
    let method: String
    let minTrainIntervals: Int
    let predictions: Int
    let modelMAE: Double?
    let baselineMAE: Double?
    let modelBias: Double?
    let baselineBias: Double?
    let baselinePredictions: Int?
    let eligibleIntervals: Int?
    let excludedDateIntervals: Int?
    let insufficientHistoryIntervals: Int?
    let predictionRows: [FuelValidationPrediction]?
    enum CodingKeys: String, CodingKey {
        case method
        case minTrainIntervals = "min_train_intervals"
        case predictions = "n_predictions"
        case modelMAE = "model_mae_l"
        case baselineMAE = "baseline_mae_l"
        case modelBias = "model_bias_l"
        case baselineBias = "baseline_bias_l"
        case baselinePredictions = "baseline_n_predictions"
        case eligibleIntervals = "eligible_intervals"
        case excludedDateIntervals = "excluded_date_intervals"
        case insufficientHistoryIntervals = "insufficient_history_intervals"
        case predictionRows = "predictions"
    }
    init(method: String, minTrainIntervals: Int, predictions: Int, modelMAE: Double? = nil, baselineMAE: Double? = nil, modelBias: Double? = nil, baselineBias: Double? = nil, baselinePredictions: Int? = nil, eligibleIntervals: Int? = nil, excludedDateIntervals: Int? = nil, insufficientHistoryIntervals: Int? = nil, predictionRows: [FuelValidationPrediction]? = nil) {
        self.method = method
        self.minTrainIntervals = minTrainIntervals
        self.predictions = predictions
        self.modelMAE = modelMAE
        self.baselineMAE = baselineMAE
        self.modelBias = modelBias
        self.baselineBias = baselineBias
        self.baselinePredictions = baselinePredictions
        self.eligibleIntervals = eligibleIntervals
        self.excludedDateIntervals = excludedDateIntervals
        self.insufficientHistoryIntervals = insufficientHistoryIntervals
        self.predictionRows = predictionRows
    }
}

struct FuelCoefficients: Decodable, Sendable {
    let cityL100: Double?
    let highwayL100: Double?
    let idleLPH: Double?
    enum CodingKeys: String, CodingKey {
        case cityL100 = "city_l100"
        case highwayL100 = "hwy_l100"
        case idleLPH = "idle_lph"
    }
    init(cityL100: Double? = nil, highwayL100: Double? = nil, idleLPH: Double? = nil) {
        self.cityL100 = cityL100
        self.highwayL100 = highwayL100
        self.idleLPH = idleLPH
    }
}

struct FuelCalibration: Decodable, Sendable {
    let delta: Double?
    let n: Int?
    let residualSD: Double?
    let points: [CalibrationPoint]?
    enum CodingKeys: String, CodingKey {
        case delta
        case n
        case residualSD = "resid_sd"
        case points
    }
    init(delta: Double? = nil, n: Int? = nil, residualSD: Double? = nil, points: [CalibrationPoint]? = nil) {
        self.delta = delta
        self.n = n
        self.residualSD = residualSD
        self.points = points
    }
}

struct FuelInterval: Decodable, Identifiable, Sendable {
    var id: String { "\(from ?? "")-\(to ?? "")" }
    let from: String?
    let to: String?
    let km: Double?
    let litres: Double?
    let kmpl: Double?
    let status: String?
    let cityKM: Double?
    let highwayKM: Double?
    let idleHours: Double?
    let trips: Int?
    let fills: Int?
    let movingSpeedKMH: Double?
    let highwayShare: Double?
    enum CodingKeys: String, CodingKey {
        case from
        case to
        case km
        case litres
        case kmpl
        case status
        case cityKM = "city_km"
        case highwayKM = "hwy_km"
        case idleHours = "idle_h"
        case trips
        case fills
        case movingSpeedKMH = "avg_moving_kmh"
        case highwayShare = "hwy_share"
    }
    init(from: String? = nil, to: String? = nil, km: Double? = nil, litres: Double? = nil, kmpl: Double? = nil, status: String? = nil, cityKM: Double? = nil, highwayKM: Double? = nil, idleHours: Double? = nil, trips: Int? = nil, fills: Int? = nil, movingSpeedKMH: Double? = nil, highwayShare: Double? = nil) {
        self.from = from
        self.to = to
        self.km = km
        self.litres = litres
        self.kmpl = kmpl
        self.status = status
        self.cityKM = cityKM
        self.highwayKM = highwayKM
        self.idleHours = idleHours
        self.trips = trips
        self.fills = fills
        self.movingSpeedKMH = movingSpeedKMH
        self.highwayShare = highwayShare
    }
}

struct FuelTrip: Decodable, Sendable {
    let id: String
    let km: Double?
    let estimatedLitres: Double?
    let cost: Double?
    let startText: String?
    let idleLitres: Double?
    let economyKMPL: Double?
    let highway: Bool?
    let movingSpeedKMH: Double?
    let idleShare: Double?
    enum CodingKeys: String, CodingKey {
        case id
        case km
        case estimatedLitres = "est_l"
        case cost
        case startText = "start"
        case idleLitres = "idle_l"
        case economyKMPL = "kmpl"
        case highway = "hwy"
        case movingSpeedKMH = "avg"
        case idleShare = "idle_share"
    }
    init(id: String, km: Double? = nil, estimatedLitres: Double? = nil, cost: Double? = nil, startText: String? = nil, idleLitres: Double? = nil, economyKMPL: Double? = nil, highway: Bool? = nil, movingSpeedKMH: Double? = nil, idleShare: Double? = nil) {
        self.id = id
        self.km = km
        self.estimatedLitres = estimatedLitres
        self.cost = cost
        self.startText = startText
        self.idleLitres = idleLitres
        self.economyKMPL = economyKMPL
        self.highway = highway
        self.movingSpeedKMH = movingSpeedKMH
        self.idleShare = idleShare
    }
}

struct PerformanceAnalytics: Decodable, Sendable {
    let trips: [PerformanceTrip]?
    let generatedAt: String?
    let deltaKMPerTrip: Double?
    let totals: PerformanceTotals?
    let monthly: [PerformanceMonth]?
    let speedBands: SpeedBandDistribution?
    let bandsByCluster: [ClusterSpeedBands]?
    let speedAcceleration: SpeedAccelerationDensity?
    let clusters: TripClusters?
    let powerLaw: JourneyDurationModel?
    let commute: CommuteReliability?
    let forecast: DistanceForecast?
    let cold: SoakDistribution?
    let correlations: CorrelationMatrix?
    let idleFuel: IdleFuelEstimate?
    let wltc: [ReferenceCycle]?
    enum CodingKeys: String, CodingKey {
        case trips
        case generatedAt = "generated_at"
        case deltaKMPerTrip = "delta_km_per_trip"
        case totals
        case monthly
        case speedBands = "speed_bands"
        case bandsByCluster = "bands_by_cluster"
        case speedAcceleration = "speed_accel"
        case clusters
        case powerLaw = "power_law"
        case commute
        case forecast
        case cold
        case correlations
        case idleFuel = "idle_fuel"
        case wltc
    }
    init(trips: [PerformanceTrip]? = nil, generatedAt: String? = nil, deltaKMPerTrip: Double? = nil, totals: PerformanceTotals? = nil, monthly: [PerformanceMonth]? = nil, speedBands: SpeedBandDistribution? = nil, bandsByCluster: [ClusterSpeedBands]? = nil, speedAcceleration: SpeedAccelerationDensity? = nil, clusters: TripClusters? = nil, powerLaw: JourneyDurationModel? = nil, commute: CommuteReliability? = nil, forecast: DistanceForecast? = nil, cold: SoakDistribution? = nil, correlations: CorrelationMatrix? = nil, idleFuel: IdleFuelEstimate? = nil, wltc: [ReferenceCycle]? = nil) {
        self.trips = trips
        self.generatedAt = generatedAt
        self.deltaKMPerTrip = deltaKMPerTrip
        self.totals = totals
        self.monthly = monthly
        self.speedBands = speedBands
        self.bandsByCluster = bandsByCluster
        self.speedAcceleration = speedAcceleration
        self.clusters = clusters
        self.powerLaw = powerLaw
        self.commute = commute
        self.forecast = forecast
        self.cold = cold
        self.correlations = correlations
        self.idleFuel = idleFuel
        self.wltc = wltc
    }
}

struct PerformanceTrip: Decodable, Sendable {
    let id: String
    let km: Double?
    let elapsedMinutes: Double?
    let startText: String?
    let movingSpeedKMH: Double?
    let overallSpeedKMH: Double?
    let maxSpeedKMH: Double?
    let idleShare: Double?
    let soakHours: Double?
    let longSoak: Bool?
    let cluster: Int?
    let pc1: Double?
    let pc2: Double?
    let events: Int?
    let rpa: Double?
    let stopsPerKM: Double?
    let p95SpeedKMH: Double?
    let stoppedShare: Double?
    let share5to20: Double?
    let share20to40: Double?
    let share40to60: Double?
    let share60to80: Double?
    let share80to100: Double?
    let share100plus: Double?
    enum CodingKeys: String, CodingKey {
        case id = "trip_id"
        case km
        case elapsedMinutes = "elapsed_min"
        case startText = "start_ts"
        case movingSpeedKMH = "avg_kmh"
        case overallSpeedKMH = "overall_kmh"
        case maxSpeedKMH = "max_kmh"
        case idleShare = "idle_share"
        case soakHours = "soak_h"
        case longSoak = "cold"
        case cluster
        case pc1
        case pc2
        case events
        case rpa
        case stopsPerKM = "stops_per_km"
        case p95SpeedKMH = "p95_kmh"
        case stoppedShare = "band_Stopped"
        case share5to20 = "band_5–20"
        case share20to40 = "band_20–40"
        case share40to60 = "band_40–60"
        case share60to80 = "band_60–80"
        case share80to100 = "band_80–100"
        case share100plus = "band_100+"
    }
    init(id: String, km: Double? = nil, elapsedMinutes: Double? = nil, startText: String? = nil, movingSpeedKMH: Double? = nil, overallSpeedKMH: Double? = nil, maxSpeedKMH: Double? = nil, idleShare: Double? = nil, soakHours: Double? = nil, longSoak: Bool? = nil, cluster: Int? = nil, pc1: Double? = nil, pc2: Double? = nil, events: Int? = nil, rpa: Double? = nil, stopsPerKM: Double? = nil, p95SpeedKMH: Double? = nil, stoppedShare: Double? = nil, share5to20: Double? = nil, share20to40: Double? = nil, share40to60: Double? = nil, share60to80: Double? = nil, share80to100: Double? = nil, share100plus: Double? = nil) {
        self.id = id
        self.km = km
        self.elapsedMinutes = elapsedMinutes
        self.startText = startText
        self.movingSpeedKMH = movingSpeedKMH
        self.overallSpeedKMH = overallSpeedKMH
        self.maxSpeedKMH = maxSpeedKMH
        self.idleShare = idleShare
        self.soakHours = soakHours
        self.longSoak = longSoak
        self.cluster = cluster
        self.pc1 = pc1
        self.pc2 = pc2
        self.events = events
        self.rpa = rpa
        self.stopsPerKM = stopsPerKM
        self.p95SpeedKMH = p95SpeedKMH
        self.stoppedShare = stoppedShare
        self.share5to20 = share5to20
        self.share20to40 = share20to40
        self.share40to60 = share40to60
        self.share60to80 = share60to80
        self.share80to100 = share80to100
        self.share100plus = share100plus
    }
    var speedBandShares: [String: Double?] {
        ["Stopped": stoppedShare, "5–20": share5to20, "20–40": share20to40, "40–60": share40to60,
         "60–80": share60to80, "80–100": share80to100, "100+": share100plus]
    }
}

struct RunningCost: Decodable, Sendable {
    let km: Double?
    let fuelRS: Double?
    let serviceRS: Double?
    let otherRS: Double?
    let perKM: RunningCostRates?
    enum CodingKeys: String, CodingKey {
        case km
        case fuelRS = "fuel_rs"
        case serviceRS = "service_rs"
        case otherRS = "other_rs"
        case perKM = "per_km"
    }
    init(km: Double? = nil, fuelRS: Double? = nil, serviceRS: Double? = nil, otherRS: Double? = nil, perKM: RunningCostRates? = nil) {
        self.km = km
        self.fuelRS = fuelRS
        self.serviceRS = serviceRS
        self.otherRS = otherRS
        self.perKM = perKM
    }
}

struct RunningCostRates: Decodable, Sendable {
    let fuel: Double?
    let service: Double?
    let other: Double?
    let total: Double?
    enum CodingKeys: String, CodingKey {
        case fuel
        case service
        case other
        case total
    }
    init(fuel: Double? = nil, service: Double? = nil, other: Double? = nil, total: Double? = nil) {
        self.fuel = fuel
        self.service = service
        self.other = other
        self.total = total
    }
}

struct InferredPlace: Decodable, Identifiable, Sendable {
    var id: String { name }
    let name: String
    let latitude: Double?
    let longitude: Double?
    let visits: Int?
    enum CodingKeys: String, CodingKey {
        case name
        case latitude = "lat"
        case longitude = "lon"
        case visits
    }
    init(name: String, latitude: Double? = nil, longitude: Double? = nil, visits: Int? = nil) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.visits = visits
    }
}

struct TrafficHotspot: Decodable, Identifiable, Sendable {
    var id: String { "\(latitude.map(String.init(describing:)) ?? "?")-\(longitude.map(String.init(describing:)) ?? "?")" }
    let latitude: Double?
    let longitude: Double?
    let minutes: Double?
    let trips: Int?
    let minutesPerTrip: Double?
    enum CodingKeys: String, CodingKey {
        case latitude = "lat"
        case longitude = "lon"
        case minutes
        case trips
        case minutesPerTrip = "per_trip"
    }
    init(latitude: Double? = nil, longitude: Double? = nil, minutes: Double? = nil, trips: Int? = nil, minutesPerTrip: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.minutes = minutes
        self.trips = trips
        self.minutesPerTrip = minutesPerTrip
    }
}

struct OverviewCommute: Decodable, Sendable {
    let toWork: [OverviewCommuteTrip]?
    let toHome: [OverviewCommuteTrip]?
    enum CodingKeys: String, CodingKey {
        case toWork = "to_work"
        case toHome = "to_home"
    }
    init(toWork: [OverviewCommuteTrip]? = nil, toHome: [OverviewCommuteTrip]? = nil) {
        self.toWork = toWork
        self.toHome = toHome
    }
}

struct OverviewCommuteTrip: Decodable, Sendable {
    let startText: String?
    let minutes: Double?
    let km: Double?
    enum CodingKeys: String, CodingKey {
        case startText = "start"
        case minutes = "min"
        case km
    }
    init(startText: String? = nil, minutes: Double? = nil, km: Double? = nil) {
        self.startText = startText
        self.minutes = minutes
        self.km = km
    }
}

struct OdometerMilestone: Decodable, Sendable {
    let km: Double?
    let date: String?
    enum CodingKeys: String, CodingKey {
        case km
        case date
    }
    init(km: Double? = nil, date: String? = nil) {
        self.km = km
        self.date = date
    }
}

struct FuelConstants: Decodable, Sendable {
    let tankLitres: Double?
    let referenceKMPL: Double?
    let legacyBrimLitres: Double?
    let highwayThresholdKMH: Double?
    let premiumMarkup: Double?
    enum CodingKeys: String, CodingKey {
        case tankLitres = "tank_l"
        case referenceKMPL = "arai_kmpl"
        case legacyBrimLitres = "brim_l"
        case highwayThresholdKMH = "hwy_kmh"
        case premiumMarkup = "premium_markup"
    }
    init(tankLitres: Double? = nil, referenceKMPL: Double? = nil, legacyBrimLitres: Double? = nil, highwayThresholdKMH: Double? = nil, premiumMarkup: Double? = nil) {
        self.tankLitres = tankLitres
        self.referenceKMPL = referenceKMPL
        self.legacyBrimLitres = legacyBrimLitres
        self.highwayThresholdKMH = highwayThresholdKMH
        self.premiumMarkup = premiumMarkup
    }
}

struct CalibrationPoint: Decodable, Sendable {
    let date: String?
    let loggedKM: Double?
    let rebuiltRawKM: Double?
    let rebuiltKM: Double?
    let residualKM: Double?
    let tripsAfter: Int?
    enum CodingKeys: String, CodingKey {
        case date
        case loggedKM = "logged_km"
        case rebuiltRawKM = "rebuilt_raw"
        case rebuiltKM = "rebuilt"
        case residualKM = "resid"
        case tripsAfter = "trips_after"
    }
    init(date: String? = nil, loggedKM: Double? = nil, rebuiltRawKM: Double? = nil, rebuiltKM: Double? = nil, residualKM: Double? = nil, tripsAfter: Int? = nil) {
        self.date = date
        self.loggedKM = loggedKM
        self.rebuiltRawKM = rebuiltRawKM
        self.rebuiltKM = rebuiltKM
        self.residualKM = residualKM
        self.tripsAfter = tripsAfter
    }
}

struct FuelFill: Decodable, Sendable {
    let date: String?
    let moment: String?
    let station: String?
    let brand: String?
    let imputed: String?
    let litres: Double?
    let amount: Double?
    let rate: Double?
    let loggedKM: Double?
    let odometerKM: Double?
    let premium: Bool?
    let brim: Bool?
    let overTank: Bool?
    enum CodingKeys: String, CodingKey {
        case date
        case moment
        case station
        case brand
        case imputed
        case litres
        case amount
        case rate
        case loggedKM = "logged_km"
        case odometerKM = "odo"
        case premium
        case brim
        case overTank = "over_tank"
    }
    init(date: String? = nil, moment: String? = nil, station: String? = nil, brand: String? = nil, imputed: String? = nil, litres: Double? = nil, amount: Double? = nil, rate: Double? = nil, loggedKM: Double? = nil, odometerKM: Double? = nil, premium: Bool? = nil, brim: Bool? = nil, overTank: Bool? = nil) {
        self.date = date
        self.moment = moment
        self.station = station
        self.brand = brand
        self.imputed = imputed
        self.litres = litres
        self.amount = amount
        self.rate = rate
        self.loggedKM = loggedKM
        self.odometerKM = odometerKM
        self.premium = premium
        self.brim = brim
        self.overTank = overTank
    }
}

struct FuelMonth: Decodable, Identifiable, Sendable {
    var id: String { month }
    let month: String
    let km: Double?
    let estimatedLitres: Double?
    let estimatedCost: Double?
    let idleCost: Double?
    let spend: Double?
    let litres: Double?
    enum CodingKeys: String, CodingKey {
        case month
        case km
        case estimatedLitres = "est_l"
        case estimatedCost = "est_cost"
        case idleCost = "idle_cost"
        case spend
        case litres
    }
    init(month: String, km: Double? = nil, estimatedLitres: Double? = nil, estimatedCost: Double? = nil, idleCost: Double? = nil, spend: Double? = nil, litres: Double? = nil) {
        self.month = month
        self.km = km
        self.estimatedLitres = estimatedLitres
        self.estimatedCost = estimatedCost
        self.idleCost = idleCost
        self.spend = spend
        self.litres = litres
    }
    var date: Date? { AnalyticsDate.parse(month + "-01") }
}

struct FuelBrand: Decodable, Identifiable, Sendable {
    var id: String { brand }
    let brand: String
    let fills: Int?
    let litres: Double?
    let spend: Double?
    let rate: Double?
    enum CodingKeys: String, CodingKey {
        case brand
        case fills
        case litres
        case spend
        case rate
    }
    init(brand: String, fills: Int? = nil, litres: Double? = nil, spend: Double? = nil, rate: Double? = nil) {
        self.brand = brand
        self.fills = fills
        self.litres = litres
        self.spend = spend
        self.rate = rate
    }
}

struct MissingFuelInterval: Decodable, Sendable {
    let from: String?
    let to: String?
    let km: Double?
    let loggedLitres: Double?
    let neededLitres: Double?
    let unloggedLitres: Double?
    enum CodingKeys: String, CodingKey {
        case from
        case to
        case km
        case loggedLitres = "logged_l"
        case neededLitres = "needed_l"
        case unloggedLitres = "unlogged_l"
    }
    init(from: String? = nil, to: String? = nil, km: Double? = nil, loggedLitres: Double? = nil, neededLitres: Double? = nil, unloggedLitres: Double? = nil) {
        self.from = from
        self.to = to
        self.km = km
        self.loggedLitres = loggedLitres
        self.neededLitres = neededLitres
        self.unloggedLitres = unloggedLitres
    }
}

struct GaussianPrior: Decodable, Sendable {
    let mean: Double?
    let sd: Double?
    enum CodingKeys: String, CodingKey {
        case mean
        case sd
    }
    init(mean: Double? = nil, sd: Double? = nil) {
        self.mean = mean
        self.sd = sd
    }
}

struct DensityCurve: Decodable, Sendable {
    let x: [Double?]?
    let prior: [Double?]?
    let posterior: [Double?]?
    enum CodingKeys: String, CodingKey {
        case x
        case prior
        case posterior
    }
    init(x: [Double?]? = nil, prior: [Double?]? = nil, posterior: [Double?]? = nil) {
        self.x = x
        self.prior = prior
        self.posterior = posterior
    }
}

struct NoiseEvidence: Decodable, Sendable {
    let sigma: [Double?]?
    let logEvidence: [Double?]?
    enum CodingKeys: String, CodingKey {
        case sigma
        case logEvidence = "log_evidence"
    }
    init(sigma: [Double?]? = nil, logEvidence: [Double?]? = nil) {
        self.sigma = sigma
        self.logEvidence = logEvidence
    }
}

struct FuelFitPoint: Decodable, Sendable {
    let from: String?
    let to: String?
    let actualLitres: Double?
    let predictedLitres: Double?
    enum CodingKeys: String, CodingKey {
        case from
        case to
        case actualLitres = "actual"
        case predictedLitres = "pred"
    }
    init(from: String? = nil, to: String? = nil, actualLitres: Double? = nil, predictedLitres: Double? = nil) {
        self.from = from
        self.to = to
        self.actualLitres = actualLitres
        self.predictedLitres = predictedLitres
    }
}

struct FuelValidationPrediction: Decodable, Sendable {
    let from: String?
    let to: String?
    let trainIntervals: Int?
    let sigmaLitres: Double?
    let actualLitres: Double?
    let predictedLitres: Double?
    let baselineLitres: Double?
    let errorLitres: Double?
    let baselineErrorLitres: Double?
    enum CodingKeys: String, CodingKey {
        case from
        case to
        case trainIntervals = "train_intervals"
        case sigmaLitres = "sigma_l"
        case actualLitres = "actual_l"
        case predictedLitres = "predicted_l"
        case baselineLitres = "baseline_l"
        case errorLitres = "error_l"
        case baselineErrorLitres = "baseline_error_l"
    }
    init(from: String? = nil, to: String? = nil, trainIntervals: Int? = nil, sigmaLitres: Double? = nil, actualLitres: Double? = nil, predictedLitres: Double? = nil, baselineLitres: Double? = nil, errorLitres: Double? = nil, baselineErrorLitres: Double? = nil) {
        self.from = from
        self.to = to
        self.trainIntervals = trainIntervals
        self.sigmaLitres = sigmaLitres
        self.actualLitres = actualLitres
        self.predictedLitres = predictedLitres
        self.baselineLitres = baselineLitres
        self.errorLitres = errorLitres
        self.baselineErrorLitres = baselineErrorLitres
    }
}

struct TankHistory: Decodable, Sendable {
    let points: [TankPoint]?
    let gauge: [FuelGaugeReading]?
    let fills: [TankFill]?
    let gaps: [TimeRange]?
    enum CodingKeys: String, CodingKey {
        case points
        case gauge
        case fills
        case gaps
    }
    init(points: [TankPoint]? = nil, gauge: [FuelGaugeReading]? = nil, fills: [TankFill]? = nil, gaps: [TimeRange]? = nil) {
        self.points = points
        self.gauge = gauge
        self.fills = fills
        self.gaps = gaps
    }
}

struct PerformanceTotals: Decodable, Sendable {
    let trips: Int?
    let km: Double?
    let engineHours: Double?
    let kmPerEngineHour: Double?
    let routed: Int?
    let rpaMedian: Double?
    let stopsPerKMMedian: Double?
    let idleHours: Double?
    enum CodingKeys: String, CodingKey {
        case trips
        case km
        case engineHours = "engine_h"
        case kmPerEngineHour = "km_per_engine_h"
        case routed
        case rpaMedian = "rpa_median"
        case stopsPerKMMedian = "stops_per_km_median"
        case idleHours = "idle_h"
    }
    init(trips: Int? = nil, km: Double? = nil, engineHours: Double? = nil, kmPerEngineHour: Double? = nil, routed: Int? = nil, rpaMedian: Double? = nil, stopsPerKMMedian: Double? = nil, idleHours: Double? = nil) {
        self.trips = trips
        self.km = km
        self.engineHours = engineHours
        self.kmPerEngineHour = kmPerEngineHour
        self.routed = routed
        self.rpaMedian = rpaMedian
        self.stopsPerKMMedian = stopsPerKMMedian
        self.idleHours = idleHours
    }
}

struct PerformanceMonth: Decodable, Identifiable, Sendable {
    var id: String { month }
    let month: String
    let km: Double?
    let trips: Int?
    let movingSpeedKMH: Double?
    let overallSpeedKMH: Double?
    let idleShare: Double?
    let engineHours: Double?
    let events: Double?
    enum CodingKeys: String, CodingKey {
        case month
        case km
        case trips
        case movingSpeedKMH = "moving_kmh"
        case overallSpeedKMH = "overall_kmh"
        case idleShare = "idle_share"
        case engineHours = "engine_h"
        case events
    }
    init(month: String, km: Double? = nil, trips: Int? = nil, movingSpeedKMH: Double? = nil, overallSpeedKMH: Double? = nil, idleShare: Double? = nil, engineHours: Double? = nil, events: Double? = nil) {
        self.month = month
        self.km = km
        self.trips = trips
        self.movingSpeedKMH = movingSpeedKMH
        self.overallSpeedKMH = overallSpeedKMH
        self.idleShare = idleShare
        self.engineHours = engineHours
        self.events = events
    }
    var date: Date? { AnalyticsDate.parse(month + "-01") }
}

struct SpeedBandDistribution: Decodable, Sendable {
    let bands: [String]?
    let share: [Double?]?
    enum CodingKeys: String, CodingKey {
        case bands
        case share
    }
    init(bands: [String]? = nil, share: [Double?]? = nil) {
        self.bands = bands
        self.share = share
    }
}

struct ClusterSpeedBands: Decodable, Sendable {
    let cluster: Int?
    let n: Int?
    let share: [Double?]?
    enum CodingKeys: String, CodingKey {
        case cluster
        case n
        case share
    }
    init(cluster: Int? = nil, n: Int? = nil, share: [Double?]? = nil) {
        self.cluster = cluster
        self.n = n
        self.share = share
    }
}

struct SpeedAccelerationDensity: Decodable, Sendable {
    let speedEdges: [Double?]?
    let accelerationEdges: [Double?]?
    let seconds: [[Double?]]?
    enum CodingKeys: String, CodingKey {
        case speedEdges = "speed_edges"
        case accelerationEdges = "acc_edges"
        case seconds
    }
    init(speedEdges: [Double?]? = nil, accelerationEdges: [Double?]? = nil, seconds: [[Double?]]? = nil) {
        self.speedEdges = speedEdges
        self.accelerationEdges = accelerationEdges
        self.seconds = seconds
    }
}

struct TripClusters: Decodable, Sendable {
    let k: Int?
    let silhouette: [String: Double?]?
    let features: [String]?
    let explainedVariance: [Double?]?
    let loadings: [String: [Double?]]?
    let profiles: [ClusterProfile]?
    enum CodingKeys: String, CodingKey {
        case k
        case silhouette
        case features
        case explainedVariance = "explained_variance"
        case loadings
        case profiles
    }
    init(k: Int? = nil, silhouette: [String: Double?]? = nil, features: [String]? = nil, explainedVariance: [Double?]? = nil, loadings: [String: [Double?]]? = nil, profiles: [ClusterProfile]? = nil) {
        self.k = k
        self.silhouette = silhouette
        self.features = features
        self.explainedVariance = explainedVariance
        self.loadings = loadings
        self.profiles = profiles
    }
}

struct ClusterProfile: Decodable, Identifiable, Sendable {
    var id: String { String(cluster) }
    let cluster: Int
    let name: String?
    let trips: Int?
    let km: Double?
    let overallSpeedKMH: Double?
    let idleShare: Double?
    let maxSpeedKMH: Double?
    let minutes: Double?
    let totalKM: Double?
    let distanceShare: Double?
    enum CodingKeys: String, CodingKey {
        case cluster
        case name
        case trips = "n"
        case km
        case overallSpeedKMH = "overall_kmh"
        case idleShare = "idle_share"
        case maxSpeedKMH = "max_kmh"
        case minutes
        case totalKM = "km_total"
        case distanceShare = "share_km"
    }
    init(cluster: Int, name: String? = nil, trips: Int? = nil, km: Double? = nil, overallSpeedKMH: Double? = nil, idleShare: Double? = nil, maxSpeedKMH: Double? = nil, minutes: Double? = nil, totalKM: Double? = nil, distanceShare: Double? = nil) {
        self.cluster = cluster
        self.name = name
        self.trips = trips
        self.km = km
        self.overallSpeedKMH = overallSpeedKMH
        self.idleShare = idleShare
        self.maxSpeedKMH = maxSpeedKMH
        self.minutes = minutes
        self.totalKM = totalKM
        self.distanceShare = distanceShare
    }
}

struct JourneyDurationModel: Decodable, Sendable {
    let intercept: Double?
    let exponent: Double?
    let residualSD: Double?
    let r2: Double?
    let sampleCount: Int?
    let band: DurationBand?
    let outliers: [DurationOutlier]?
    enum CodingKeys: String, CodingKey {
        case intercept = "a"
        case exponent = "b"
        case residualSD = "s"
        case r2
        case sampleCount = "n"
        case band
        case outliers
    }
    init(intercept: Double? = nil, exponent: Double? = nil, residualSD: Double? = nil, r2: Double? = nil, sampleCount: Int? = nil, band: DurationBand? = nil, outliers: [DurationOutlier]? = nil) {
        self.intercept = intercept
        self.exponent = exponent
        self.residualSD = residualSD
        self.r2 = r2
        self.sampleCount = sampleCount
        self.band = band
        self.outliers = outliers
    }
}

struct DurationBand: Decodable, Sendable {
    let km: [Double?]?
    let fit: [Double?]?
    let low: [Double?]?
    let high: [Double?]?
    enum CodingKeys: String, CodingKey {
        case km
        case fit
        case low = "lo"
        case high = "hi"
    }
    init(km: [Double?]? = nil, fit: [Double?]? = nil, low: [Double?]? = nil, high: [Double?]? = nil) {
        self.km = km
        self.fit = fit
        self.low = low
        self.high = high
    }
}

struct DurationOutlier: Decodable, Sendable {
    let id: String
    let startText: String?
    let km: Double?
    let minutes: Double?
    let expectedMinutes: Double?
    let studentizedResidual: Double?
    let idleMinutes: Double?
    enum CodingKeys: String, CodingKey {
        case id
        case startText = "start"
        case km
        case minutes
        case expectedMinutes = "expected"
        case studentizedResidual = "stud"
        case idleMinutes = "idle_min"
    }
    init(id: String, startText: String? = nil, km: Double? = nil, minutes: Double? = nil, expectedMinutes: Double? = nil, studentizedResidual: Double? = nil, idleMinutes: Double? = nil) {
        self.id = id
        self.startText = startText
        self.km = km
        self.minutes = minutes
        self.expectedMinutes = expectedMinutes
        self.studentizedResidual = studentizedResidual
        self.idleMinutes = idleMinutes
    }
}

struct CommuteReliability: Decodable, Sendable {
    let toWork: CommuteDirection?
    let toHome: CommuteDirection?
    enum CodingKeys: String, CodingKey {
        case toWork = "to_work"
        case toHome = "to_home"
    }
    init(toWork: CommuteDirection? = nil, toHome: CommuteDirection? = nil) {
        self.toWork = toWork
        self.toHome = toHome
    }
}

struct CommuteDirection: Decodable, Sendable {
    let n: Int?
    let freeFlow: Double?
    let median: Double?
    let mean: Double?
    let p95: Double?
    let planningTimeIndex: Double?
    let bufferTimeIndex: Double?
    let km: Double?
    let minutes: [Double?]?
    let bySlot: [CommuteSlot]?
    let byWeekday: [WeekdayDuration]?
    let trips: [CommuteTrip]?
    enum CodingKeys: String, CodingKey {
        case n
        case freeFlow = "free_flow"
        case median
        case mean
        case p95
        case planningTimeIndex = "pti"
        case bufferTimeIndex = "bti"
        case km
        case minutes
        case bySlot = "by_slot"
        case byWeekday = "by_weekday"
        case trips
    }
    init(n: Int? = nil, freeFlow: Double? = nil, median: Double? = nil, mean: Double? = nil, p95: Double? = nil, planningTimeIndex: Double? = nil, bufferTimeIndex: Double? = nil, km: Double? = nil, minutes: [Double?]? = nil, bySlot: [CommuteSlot]? = nil, byWeekday: [WeekdayDuration]? = nil, trips: [CommuteTrip]? = nil) {
        self.n = n
        self.freeFlow = freeFlow
        self.median = median
        self.mean = mean
        self.p95 = p95
        self.planningTimeIndex = planningTimeIndex
        self.bufferTimeIndex = bufferTimeIndex
        self.km = km
        self.minutes = minutes
        self.bySlot = bySlot
        self.byWeekday = byWeekday
        self.trips = trips
    }
}

struct DistanceForecast: Decodable, Sendable {
    let history: [DatedValue]?
    let future: [ForecastPoint]?
    let kmPerDay: Double?
    let sdPerDay: Double?
    let windowDays: Int?
    let milestones: [ForecastMilestone]?
    let weekly: [DatedValue]?
    enum CodingKeys: String, CodingKey {
        case history
        case future
        case kmPerDay = "km_per_day"
        case sdPerDay = "sd_per_day"
        case windowDays = "window_days"
        case milestones
        case weekly
    }
    init(history: [DatedValue]? = nil, future: [ForecastPoint]? = nil, kmPerDay: Double? = nil, sdPerDay: Double? = nil, windowDays: Int? = nil, milestones: [ForecastMilestone]? = nil, weekly: [DatedValue]? = nil) {
        self.history = history
        self.future = future
        self.kmPerDay = kmPerDay
        self.sdPerDay = sdPerDay
        self.windowDays = windowDays
        self.milestones = milestones
        self.weekly = weekly
    }
}

struct ForecastMilestone: Decodable, Sendable {
    let km: Double?
    let medianDate: String?
    let early: String?
    let late: String?
    enum CodingKeys: String, CodingKey {
        case km
        case medianDate = "p50"
        case early
        case late
    }
    init(km: Double? = nil, medianDate: String? = nil, early: String? = nil, late: String? = nil) {
        self.km = km
        self.medianDate = medianDate
        self.early = early
        self.late = late
    }
}

struct SoakDistribution: Decodable, Sendable {
    let labels: [String]?
    let counts: [Double?]?
    let coldShare: Double?
    let shortCold: Int?
    let shortColdShare: Double?
    let shortColdKM: Double?
    let thresholdHours: Double?
    enum CodingKeys: String, CodingKey {
        case labels
        case counts
        case coldShare = "cold_share"
        case shortCold = "short_cold"
        case shortColdShare = "short_cold_share"
        case shortColdKM = "short_cold_km"
        case thresholdHours = "threshold_h"
    }
    init(labels: [String]? = nil, counts: [Double?]? = nil, coldShare: Double? = nil, shortCold: Int? = nil, shortColdShare: Double? = nil, shortColdKM: Double? = nil, thresholdHours: Double? = nil) {
        self.labels = labels
        self.counts = counts
        self.coldShare = coldShare
        self.shortCold = shortCold
        self.shortColdShare = shortColdShare
        self.shortColdKM = shortColdKM
        self.thresholdHours = thresholdHours
    }
}

struct CorrelationMatrix: Decodable, Sendable {
    let labels: [String]?
    let matrix: [[Double?]]?
    enum CodingKeys: String, CodingKey {
        case labels
        case matrix
    }
    init(labels: [String]? = nil, matrix: [[Double?]]? = nil) {
        self.labels = labels
        self.matrix = matrix
    }
}

struct IdleFuelEstimate: Decodable, Sendable {
    let litresPerHour: Double?
    let litres: Double?
    enum CodingKeys: String, CodingKey {
        case litresPerHour = "lph"
        case litres
    }
    init(litresPerHour: Double? = nil, litres: Double? = nil) {
        self.litresPerHour = litresPerHour
        self.litres = litres
    }
}

struct ReferenceCycle: Decodable, Identifiable, Sendable {
    var id: String { phase }
    let phase: String
    let averageSpeedKMH: Double?
    let maxSpeedKMH: Double?
    enum CodingKeys: String, CodingKey {
        case phase
        case averageSpeedKMH = "avg_kmh"
        case maxSpeedKMH = "max_kmh"
    }
    init(phase: String, averageSpeedKMH: Double? = nil, maxSpeedKMH: Double? = nil) {
        self.phase = phase
        self.averageSpeedKMH = averageSpeedKMH
        self.maxSpeedKMH = maxSpeedKMH
    }
}

// The shared analytics uses compact positional rows for several series. Decode them once into
// named fields so chart consumers cannot accidentally swap fuel %, range, time or confidence bounds.
private extension UnkeyedDecodingContainer {
    mutating func next<T: Decodable>(_ type: T.Type) throws -> T? {
        isAtEnd ? nil : try decodeIfPresent(type)
    }
}

struct OverviewDay: Decodable, Identifiable, Sendable {
    var id: String { day }
    let day: String
    let distanceKM: Double?
    let tripCount: Int?
    var date: Date? { AnalyticsDate.parse(day) }
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        day = try c.decode(String.self); distanceKM = try c.next(Double.self); tripCount = try c.next(Int.self)
    }
}
struct OverviewMonth: Decodable, Identifiable, Sendable {
    var id: String { month }
    let month: String
    let distanceKM: Double?
    let tripCount: Int?
    let movingSpeedKMH: Double?
    var date: Date? { AnalyticsDate.parse(month + "-01") }
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        month = try c.decode(String.self); distanceKM = try c.next(Double.self)
        tripCount = try c.next(Int.self); movingSpeedKMH = try c.next(Double.self)
    }
}
struct HourlyIdle: Decodable, Sendable {
    let hour: Double?
    let idleShare: Double?
    let tripCount: Int?
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        hour = try c.next(Double.self); idleShare = try c.next(Double.self); tripCount = try c.next(Int.self)
    }
}
struct CommuteSlot: Decodable, Sendable {
    let hour: Double?
    let medianMinutes: Double?
    let tripCount: Int?
    let lowerQuartile: Double?
    let upperQuartile: Double?
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        hour = try c.next(Double.self); medianMinutes = try c.next(Double.self); tripCount = try c.next(Int.self)
        lowerQuartile = try c.next(Double.self); upperQuartile = try c.next(Double.self)
    }
}
struct WeekdayDuration: Decodable, Sendable {
    let weekday: Int?
    let medianMinutes: Double?
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer(); weekday = try c.next(Int.self); medianMinutes = try c.next(Double.self)
    }
}
struct CommuteTrip: Decodable, Sendable {
    let startText: String?
    let minutes: Double?
    let idleShare: Double?
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        startText = try c.next(String.self); minutes = try c.next(Double.self); idleShare = try c.next(Double.self)
    }
}
struct FuelGaugeReading: Decodable, Sendable {
    let timestamp: String
    let fuelPercent: Double?
    let rangeKM: Double?
    let modelPercent: Double?
    var date: Date? { AnalyticsDate.parse(timestamp) }
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        timestamp = try c.decode(String.self); fuelPercent = try c.next(Double.self)
        rangeKM = try c.next(Double.self); modelPercent = try c.next(Double.self)
    }
}
struct TankPoint: Decodable, Sendable {
    let timestamp: String
    let litres: Double?
    let standardDeviationLitres: Double?
    var date: Date? { AnalyticsDate.parse(timestamp) }
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        timestamp = try c.decode(String.self); litres = try c.next(Double.self); standardDeviationLitres = try c.next(Double.self)
    }
}
struct TankFill: Decodable, Sendable {
    let timestamp: String
    let litres: Double?
    let brim: Bool?
    var date: Date? { AnalyticsDate.parse(timestamp) }
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        timestamp = try c.decode(String.self); litres = try c.next(Double.self); brim = try c.next(Bool.self)
    }
}
struct TimeRange: Decodable, Sendable {
    let from: String?
    let to: String?
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer(); from = try c.next(String.self); to = try c.next(String.self)
    }
}
struct DatedValue: Decodable, Sendable {
    let timestamp: String
    let value: Double?
    var date: Date? { AnalyticsDate.parse(timestamp) }
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer(); timestamp = try c.decode(String.self); value = try c.next(Double.self)
    }
}
struct ForecastPoint: Decodable, Sendable {
    let day: String
    let mean: Double?
    let lower: Double?
    let upper: Double?
    var date: Date? { AnalyticsDate.parse(day) }
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        day = try c.decode(String.self); mean = try c.next(Double.self); lower = try c.next(Double.self); upper = try c.next(Double.self)
    }
}

/// Descriptive summaries of archived provider trip records. Every total requires complete values
/// for that metric; an unavailable distance or idle time is never silently replaced by zero.
struct DrivingBucket: Identifiable, Sendable {
    var id: String { key }
    var day: String { key }
    var month: String { key }
    let key: String
    let date: Date?
    let weekday: Int?
    let hour: Int?
    let tripCount: Int
    let distanceKM: Double?
    let elapsedMinutes: Double?
    let driveMinutes: Double?
    let idleMinutes: Double?
    let idleShare: Double?
    let estimatedFuelCost: Double?
    let fuelCostTripCount: Int
    let events: Int?
}
struct DrivingHistory: Sendable {
    let daily: [DrivingBucket]
    let monthly: [DrivingBucket]
    /// Monday=0 … Sunday=6, with only observed driving weekdays represented.
    let weekdays: [DrivingBucket]
    let hours: [DrivingBucket]
    let tripCount: Int
    let firstDate: Date?
    let lastDate: Date?

    init(trips: [NativeTrip]) {
        let dated = trips.filter { $0.start != nil }
        let calendar = AnalyticsDate.calendar
        let dailyGroups = Dictionary(grouping: dated, by: \.day)
        daily = dailyGroups.keys.sorted().map { key in
            Self.bucket(key: key, date: AnalyticsDate.parse(key), trips: dailyGroups[key]!)
        }
        let monthGroups = Dictionary(grouping: dated, by: { String($0.day.prefix(7)) })
        monthly = monthGroups.keys.sorted().map { key in
            Self.bucket(key: key, date: AnalyticsDate.parse(key + "-01"), trips: monthGroups[key]!)
        }
        let weekdayGroups = Dictionary(grouping: dated, by: { (calendar.component(.weekday, from: $0.start!) + 5) % 7 })
        weekdays = weekdayGroups.keys.sorted().map { key in
            Self.bucket(key: String(key), weekday: key, trips: weekdayGroups[key]!)
        }
        let hourGroups = Dictionary(grouping: dated, by: { calendar.component(.hour, from: $0.start!) })
        hours = hourGroups.keys.sorted().map { key in
            Self.bucket(key: String(key), hour: key, trips: hourGroups[key]!)
        }
        tripCount = trips.count
        firstDate = dated.compactMap(\.start).min()
        lastDate = dated.compactMap(\.start).max()
    }
    private static func bucket(key: String, date: Date? = nil, weekday: Int? = nil, hour: Int? = nil, trips: [NativeTrip]) -> DrivingBucket {
        let moving = InsightStatistics.completeSum(trips.map(\.driveMinutes))
        let idle = InsightStatistics.completeSum(trips.map(\.idleMinutes))
        let share = moving.flatMap { m in idle.flatMap { s in m + s > 0 ? s / (m + s) : nil } }
        let eventValues = trips.map { $0.events.map(Double.init) }
        return DrivingBucket(key: key, date: date, weekday: weekday, hour: hour, tripCount: trips.count,
                             distanceKM: InsightStatistics.completeSum(trips.map(\.distanceKM)),
                             elapsedMinutes: InsightStatistics.completeSum(trips.map(\.elapsedMinutes)),
                             driveMinutes: moving, idleMinutes: idle, idleShare: share,
                             estimatedFuelCost: InsightStatistics.completeSum(trips.map(\.estimatedFuelCost)),
                             fuelCostTripCount: trips.filter { $0.estimatedFuelCost != nil }.count,
                             events: InsightStatistics.completeSum(eventValues).map(Int.init))
    }
}

enum InsightStatistics {
    static func completeSum(_ values: [Double?]) -> Double? {
        guard !values.isEmpty, values.allSatisfy({ $0?.isFinite == true }) else { return nil }
        return values.reduce(0) { $0 + $1! }
    }
    static func quantile(_ values: [Double], _ q: Double) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty, (0...1).contains(q) else { return nil }
        let position = Double(sorted.count - 1) * q
        let low = Int(position.rounded(.down)), high = Int(position.rounded(.up))
        return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
    }
}
