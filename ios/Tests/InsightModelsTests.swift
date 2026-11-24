import XCTest
#if canImport(I20Core)
import I20Core
#endif
@testable import I20Logbook

final class InsightModelsTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func test_generationIdentityDistinguishesEqualTimestampAndEqualCountSnapshots() throws {
        let overview = try decode(OverviewAnalytics.self, #"{"generated_at":"2026-10-05T12:00:00","trips":[]}"#)
        let first = AnalyticsSnapshot(overview: overview)
        let second = AnalyticsSnapshot(overview: overview)
        XCTAssertNotEqual(first.generationID, second.generationID)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "generation-contract-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for id in [UUID().uuidString.lowercased(), UUID().uuidString.lowercased()] {
            let directory = root.appending(path: id)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(#"{"generated_at":"2026-10-05T12:00:00","trips":[]}"#.utf8)
                .write(to: directory.appending(path: "data.json"))
            XCTAssertEqual(try AnalyticsSnapshot.load(from: directory).generationID, id)
        }
    }

    func test_extendedOverviewTuplesKeepPositionsUnitsAndUnknownValues() throws {
        let value = try decode(OverviewAnalytics.self, #"""
        {"days":[["2026-10-05",null,2]],"months":[["2026-10",120,4,30]],
         "rhythm":[[0,null,2]],"weekday_km":[10,null,0],"idle_by_hour":[[8.5,0.25,4]],
         "places":[{"name":"Work","lat":12.9,"lon":77.5,"visits":6}],
         "hotspots":[{"lat":12.8,"lon":77.4,"minutes":12,"trips":4,"per_trip":3}],
         "commute":{"to_work":[{"start":"2026-10-05T08:00:00","min":32,"km":10}]},
         "milestones":[{"km":10000,"date":"2026-10-05"}],"fuel":[["2026-10-05T08:00:00",70,350]],
         "running_cost":{"km":1400,"fuel_rs":900,"service_rs":250,"other_rs":50,"per_km":{"fuel":6,"service":0.2,"other":null,"total":null}},
         "totals":{"pace_90d":12.3,"days_driven":5,"idle_hours":2,"moving_kmh":30,"top_kmh":80,"short_share":0.1,"hard_brake":3,"rapid_accel":2,"overspeed":1},
         "service":[{"item":"Engine oil","every_km":10000,"every_months":12}],
         "status":{"fuel_l":25,"park":[12.9,77.5]},"findings":{"hero":"Synthetic summary","traffic":null}}
        """#)
        XCTAssertNil(value.days?.first?.distanceKM)
        XCTAssertEqual(value.days?.first?.tripCount, 2)
        XCTAssertEqual(value.months?.first?.movingSpeedKMH, 30)
        XCTAssertEqual(value.idleByHour?.first?.hour, 8.5)
        XCTAssertEqual(value.idleByHour?.first?.idleShare, 0.25)
        XCTAssertEqual(value.idleByHour?.first?.tripCount, 4)
        XCTAssertNil(value.rhythm?[0][1])
        XCTAssertEqual(value.weekdayKM?[2], 0)
        XCTAssertEqual(value.places?.first?.latitude, 12.9)
        XCTAssertEqual(value.hotspots?.first?.minutesPerTrip, 3)
        XCTAssertEqual(value.commute?.toWork?.first?.minutes, 32)
        XCTAssertEqual(value.fuelHistory?.first?.fuelPercent, 70)
        XCTAssertEqual(value.fuelHistory?.first?.rangeKM, 350)
        XCTAssertNil(value.fuelHistory?.first?.modelPercent)
        XCTAssertEqual(value.runningCost?.perKM?.fuel, 6)
        XCTAssertNil(value.runningCost?.perKM?.other)
        XCTAssertNil(value.runningCost?.perKM?.total)
        XCTAssertEqual(value.totals?.pace90d, 12.3)
        XCTAssertEqual(value.service.first?.everyKM, 10000)
        XCTAssertEqual(value.service.first?.everyMonths, 12)
        XCTAssertEqual(value.status?.park?[1], 77.5)
        let empty = try decode(OverviewAnalytics.self, "{}")
        XCTAssertNil(empty.days)
        XCTAssertNil(empty.runningCost)
        XCTAssertEqual(empty.trips.count, 0)
    }

    func test_extendedFuelEvidenceSeparatesCashModelEstimatesAndGaugeUnits() throws {
        let value = try decode(FuelAnalytics.self, #"""
        {"source":"invented","constants":{"tank_l":37,"arai_kmpl":20.35,"brim_l":30,"hwy_kmh":50,"premium_markup":1.08},
         "totals":{"fills":2,"avg_rate":100,"km_valid":200,"idle_l":1.2,"idle_cost":120,"idle_share_of_fuel":0.1,"est_l_total":12,"est_cost_total":1200,"city_share_km":0.6,"city_share_fuel":0.7,"premium_fills":1,"premium_extra":15,"unlogged_l":3,"over_tank":0,"odo_span":[1000,1200]},
         "calibration":{"delta":0.2,"n":1,"resid_sd":null,"points":[{"date":"2026-10-05","logged_km":1200,"rebuilt_raw":1202,"rebuilt":1200,"resid":0,"trips_after":10}]},
         "fills":[{"date":"2026-10-05","moment":"2026-10-05T08:00:00","station":"Invented pump","brand":"Test","litres":30,"amount":null,"rate":100,"imputed":"amount","logged_km":1200,"odo":1200,"premium":false,"brim":true,"over_tank":false}],
         "intervals":[{"from":"2026-10-01","to":"2026-10-05","km":200,"litres":20,"kmpl":10,"status":"ok","city_km":120,"hwy_km":80,"idle_h":1.5,"trips":10,"fills":2,"avg_moving_kmh":40,"hwy_share":0.4}],
         "model":{"coef":{"city_l100":8,"hwy_l100":5,"idle_lph":0.8},"prior":{"idle_lph":{"mean":0.75,"sd":0.25}},"posterior_corr":[[1,null],[null,1]],"sigma_l":2,"r2":null,"kmpl_city":12.5,"kmpl_hwy":20,
           "curves":{"idle_lph":{"x":[0,1],"prior":[0.1,0.2],"posterior":[0.05,null]}},"evidence":{"sigma":[1,2],"log_evidence":[-12,-10]},"fitted":[{"from":"2026-10-01","to":"2026-10-05","actual":20,"pred":19.5}]},
         "monthly":[{"month":"2026-10","km":200,"est_l":12,"est_cost":1200,"idle_cost":120,"spend":3000,"litres":30}],
         "brands":[{"brand":"Test","fills":2,"litres":30,"spend":3000,"rate":100}],
         "missing":[{"from":"2026-09-01","to":"2026-09-10","km":300,"logged_l":20,"needed_l":23,"unlogged_l":3}],
         "fuel_level":[["2026-10-05T08:00:00",70,300]],
         "tank":{"points":[["2026-10-05T08:00:00",25.9,0.5],["2026-10-06T08:00:00",null,null]],"gauge":[["2026-10-05T08:00:00",70,300,68]],"fills":[["2026-10-05T08:00:00",30,true]],"gaps":[["2026-10-06T08:00:00","2026-10-07T08:00:00"]]}}
        """#)
        XCTAssertEqual(value.constants?.tankLitres, 37)
        XCTAssertEqual(value.totals?.idleFuelShare, 0.1)
        XCTAssertEqual(value.totals?.cityDistanceShare, 0.6)
        XCTAssertEqual(value.totals?.cityFuelShare, 0.7)
        XCTAssertEqual(value.calibration?.points?.first?.rebuiltRawKM, 1202)
        XCTAssertEqual(value.calibration?.points?.first?.tripsAfter, 10)
        XCTAssertNil(value.calibration?.residualSD)
        XCTAssertEqual(value.fills?.first?.loggedKM, 1200)
        XCTAssertEqual(value.fills?.first?.odometerKM, 1200)
        XCTAssertNil(value.fills?.first?.amount)
        XCTAssertEqual(value.intervals?.first?.highwayShare, 0.4)
        XCTAssertEqual(value.intervals?.first?.idleHours, 1.5)
        XCTAssertEqual(value.model?.prior?["idle_lph"]?.mean, 0.75)
        XCTAssertNil(value.model?.posteriorCorrelation?[0][1])
        XCTAssertNil(value.model?.curves?["idle_lph"]?.posterior?[1])
        XCTAssertEqual(value.model?.evidence?.logEvidence?[1], -10)
        XCTAssertEqual(value.model?.fitted?.first?.predictedLitres, 19.5)
        XCTAssertEqual(value.monthly?.first?.estimatedCost, 1200)
        XCTAssertEqual(value.monthly?.first?.spend, 3000)
        XCTAssertEqual(value.missing?.first?.unloggedLitres, 3)
        XCTAssertEqual(value.tank?.points?.first?.litres, 25.9)
        XCTAssertNil(value.tank?.points?.last?.litres)
        XCTAssertNil(value.tank?.points?.last?.standardDeviationLitres)
        XCTAssertEqual(value.tank?.gauge?.first?.fuelPercent, 70)
        XCTAssertEqual(value.tank?.gauge?.first?.rangeKM, 300)
        XCTAssertEqual(value.tank?.gauge?.first?.modelPercent, 68)
        XCTAssertEqual(value.tank?.fills?.first?.brim, true)
        XCTAssertEqual(value.tank?.gaps?.first?.to, "2026-10-07T08:00:00")
        XCTAssertNil(try decode(FuelAnalytics.self, "{}").totals)
    }

    func test_performanceMatricesCommuteAndForecastKeepUncertaintyAndProxyFields() throws {
        let value = try decode(PerformanceAnalytics.self, #"""
        {"delta_km_per_trip":0.2,"totals":{"trips":10,"km":200,"engine_h":5,"km_per_engine_h":40,"routed":7,"rpa_median":0.2,"stops_per_km_median":1,"idle_h":0.5},
         "trips":[{"trip_id":"t","start_ts":"2026-10-05T08:00:00","km":20,"elapsed_min":30,"avg_kmh":50,"overall_kmh":40,"max_kmh":70,"idle_share":0.1,"soak_h":null,"cold":true,"cluster":1,"pc1":0.2,"pc2":-0.4,"events":2,"rpa":null,"stops_per_km":0.2,"p95_kmh":60,"band_Stopped":0.1,"band_5–20":0.2,"band_100+":0}],
         "wltc":[{"phase":"Low","avg_kmh":18.9,"max_kmh":56.5}],"speed_bands":{"bands":["Stopped","5–20"],"share":[0.1,null]},"bands_by_cluster":[{"cluster":1,"n":3,"share":[0.2,0.8]}],
         "speed_accel":{"speed_edges":[0,5,10],"acc_edges":[-1,0,1],"seconds":[[0,5],[null,2]]},
         "clusters":{"k":2,"silhouette":{"2":0.5,"3":null},"features":["log_km"],"explained_variance":[0.8,0.2],"loadings":{"log_km":[0.2,-0.4]},"profiles":[{"cluster":1,"name":"City trips","n":3,"km":5,"overall_kmh":20,"idle_share":0.2,"max_kmh":50,"minutes":15,"km_total":15,"share_km":0.1}]},
         "power_law":{"a":2,"b":0.6,"s":0.3,"r2":0.7,"n":10,"band":{"km":[1,2],"fit":[10,15],"lo":[5,8],"hi":[20,30]},"outliers":[{"id":"t","start":"2026-10-05T08:00:00","km":20,"minutes":50,"expected":30,"stud":2.8,"idle_min":5}]},
         "commute":{"to_work":{"n":8,"free_flow":20,"median":30,"mean":31,"p95":40,"pti":2,"bti":0.29,"km":10,"minutes":[20,30,40],"by_slot":[[8.25,30,4,25,35]],"by_weekday":[[0,28]],"trips":[["2026-10-05T08:15:00",30,0.1]]}},
         "forecast":{"history":[["2026-10-05",1200]],"future":[["2026-10-06",1220,null,1250]],"km_per_day":20,"sd_per_day":4,"window_days":120,"milestones":[{"km":5000,"p50":"2027-01-01","early":"2026-12-01","late":null}],"weekly":[["2026-10-11",140]]},
         "cold":{"labels":["<10 min","4–8 h"],"counts":[0,2],"cold_share":0.5,"short_cold":1,"short_cold_share":0.1,"short_cold_km":3,"threshold_h":4},
         "correlations":{"labels":["Distance","Duration"],"matrix":[[1,null],[null,1]]},"monthly":[{"month":"2026-10","km":200,"trips":10,"moving_kmh":50,"overall_kmh":40,"idle_share":0.1,"engine_h":5,"events":2}],"idle_fuel":{"lph":0.8,"litres":0.4}}
        """#)
        XCTAssertEqual(value.totals?.kmPerEngineHour, 40)
        XCTAssertEqual(value.trips?.first?.overallSpeedKMH, 40)
        XCTAssertNil(value.trips?.first?.soakHours)
        XCTAssertEqual(value.trips?.first?.longSoak, true)
        XCTAssertNil(value.trips?.first?.rpa)
        XCTAssertEqual(value.trips?.first?.speedBandShares["5–20"]!, 0.2)
        XCTAssertEqual(value.speedAcceleration?.accelerationEdges?[0], -1)
        XCTAssertNil(value.speedAcceleration?.seconds?[1][0])
        XCTAssertNil(value.speedBands?.share?[1])
        XCTAssertEqual(value.clusters?.profiles?.first?.totalKM, 15)
        XCTAssertEqual(value.clusters?.loadings?["log_km"]?[1], -0.4)
        XCTAssertEqual(value.powerLaw?.band?.high?[1], 30)
        XCTAssertEqual(value.powerLaw?.outliers?.first?.expectedMinutes, 30)
        XCTAssertEqual(value.commute?.toWork?.bySlot?.first?.tripCount, 4)
        XCTAssertEqual(value.commute?.toWork?.bySlot?.first?.lowerQuartile, 25)
        XCTAssertEqual(value.commute?.toWork?.byWeekday?.first?.weekday, 0)
        XCTAssertEqual(value.commute?.toWork?.trips?.first?.idleShare, 0.1)
        XCTAssertNil(value.commute?.toHome)
        XCTAssertEqual(value.forecast?.future?.first?.mean, 1220)
        XCTAssertNil(value.forecast?.future?.first?.lower)
        XCTAssertEqual(value.forecast?.milestones?.first?.medianDate, "2027-01-01")
        XCTAssertEqual(value.forecast?.weekly?.first?.value, 140)
        XCTAssertEqual(value.cold?.counts?[0], 0)
        XCTAssertEqual(value.cold?.thresholdHours, 4)
        XCTAssertNil(value.correlations?.matrix?[0][1])
        XCTAssertEqual(value.monthly?.first?.events, 2)
        XCTAssertEqual(value.idleFuel?.litresPerHour, 0.8)
        XCTAssertNil(try decode(PerformanceAnalytics.self, "{}").speedBands)
    }

    func test_cachedHistoryUsesExposureWeightsAndNeverInventsZeroDays() throws {
        let overview = try decode(OverviewAnalytics.self, #"""
        {"trips":[
          {"id":"a","start":"2026-10-05T08:00:00","end":"2026-10-05T08:20:00","km":10,"drive":10,"idle":10,"events":[0,0,0]},
          {"id":"b","start":"2026-10-05T09:00:00","end":"2026-10-05T10:30:00","km":20,"drive":90,"idle":0,"events":[0,0,0]},
          {"id":"c","start":"2026-10-07T09:00:00","end":"2026-10-07T10:00:00","km":null,"drive":55,"idle":5}
        ]}
        """#)
        let fuel = try decode(FuelAnalytics.self, #"{"trips":[{"id":"a","cost":50},{"id":"b","cost":null}]}"#)
        let snapshot = AnalyticsSnapshot(overview: overview, fuel: fuel)
        XCTAssertEqual(snapshot.history.daily.map(\.day), ["2026-10-05", "2026-10-07"])
        XCTAssertEqual(snapshot.history.daily.first?.distanceKM, 30)
        XCTAssertEqual(try XCTUnwrap(snapshot.history.daily.first?.idleShare), 1.0 / 11, accuracy: 1e-12)
        XCTAssertEqual(snapshot.history.daily.first?.events, 0)
        XCTAssertNil(snapshot.history.daily.last?.events)
        XCTAssertNil(snapshot.history.monthly.first?.distanceKM)
        XCTAssertNil(snapshot.history.monthly.first?.estimatedFuelCost)
        XCTAssertEqual(snapshot.history.monthly.first?.fuelCostTripCount, 1)
        XCTAssertEqual(snapshot.history.weekdays.compactMap(\.weekday), [0, 2])
        XCTAssertEqual(snapshot.history.hours.compactMap(\.hour), [8, 9])
        XCTAssertNil(FuelCalibration(delta: 0, n: 0, residualSD: nil).points)
        XCTAssertNil(PerformanceTrip(id: "legacy", km: nil, elapsedMinutes: nil).rpa)
    }

    func test_allHistoryRangesUseInclusiveIndiaDatesAcrossUTCDateBoundary() throws {
        let overview = try decode(OverviewAnalytics.self, #"""
        {"trips":[{"id":"india5","start":"2026-10-04T20:00:00Z"},{"id":"india6","start":"2026-10-05T20:00:00Z"},{"id":"unknown"}]}
        """#)
        let snapshot = AnalyticsSnapshot(overview: overview)
        let day = try XCTUnwrap(AnalyticsDate.parse("2026-10-05T12:00:00"))
        XCTAssertEqual(snapshot.tripRange(from: day, through: day).map(\.id), ["india5"])
        XCTAssertEqual(snapshot.trips.first { $0.id == "india5" }?.day, "2026-10-05")
        XCTAssertEqual(snapshot.history.daily.map(\.day), ["2026-10-05", "2026-10-06"])
        XCTAssertEqual(snapshot.tripRange().count, 3)
        XCTAssertEqual(snapshot.tripRange(from: day.addingTimeInterval(86400), through: day).count, 0)
    }

    #if canImport(I20Core)
    @MainActor
    func test_actualAnalyticsRunnerOutputDecodesCompleteNativeContractWithoutChangingArchive() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "rich-contract-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "book", withExtension: nil))
        let destination = root.appending(path: "i20_book")
        try fm.copyItem(at: fixture, to: destination)
        let book = Book(root: destination, writeAuthorization: BookWriteAuthorization(allowed: false))
        let files = try book.allFiles(under: "")
        let before = try Dictionary(uniqueKeysWithValues: files.map { ($0, try book.read($0)) })
        let runner = AnalyticsRunner(derivedDir: root.appending(path: "derived"))
        _ = try await runner.run(book: book, today: "2026-10-05")
        let snapshot = try AnalyticsSnapshot.load(from: runner.derivedDir)
        XCTAssertEqual(snapshot.overview.days?.count, 3)
        XCTAssertEqual(snapshot.overview.months?.first?.tripCount, 3)
        XCTAssertEqual(snapshot.fuel?.fills?.count, 3)
        XCTAssertEqual(snapshot.fuel?.tank?.points?.count, 7)
        XCTAssertEqual(snapshot.fuel?.model?.curves?["city_l100"]?.x?.count, 120)
        XCTAssertEqual(snapshot.performance?.forecast?.future?.count, 240)
        XCTAssertEqual(snapshot.performance?.correlations?.matrix?.count, 9)
        XCTAssertEqual(snapshot.performance?.clusters?.profiles?.count, 3)
        XCTAssertEqual(snapshot.history.daily.count, 3)
        XCTAssertEqual(snapshot.history.monthly.first?.distanceKM, 400)
        for path in files { XCTAssertEqual(try book.read(path), before[path], path) }
        XCTAssertEqual(try book.allFiles(under: ""), files)
    }
    #endif
}
