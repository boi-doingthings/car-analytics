import SwiftUI

struct NativePerformanceInsightsView: View {
    let snapshot: AnalyticsSnapshot
    let window: LabWindow
    @State private var speedGroup = -1
    @State private var selectedCluster = -1
    @State private var logarithmic = true
    @State private var commuteDirection = "to_work"
    @State private var trend = "Idle share"
    @State private var forecastDays = 90

    private var performance: PerformanceAnalytics? { snapshot.performance }
    private var profiles: [ClusterProfile] { performance?.clusters?.profiles ?? [] }
    @State private var trips: [NativeTrip] = []
    @State private var performanceTrips: [PerformanceTrip] = []
    private var revision: String { "\(snapshot.generationID)|\(snapshot.trips.count)|\(window.rawValue)" }
    private func name(_ cluster: Int?) -> String {
        profiles.first { $0.cluster == cluster }?.name ?? cluster.map { "Group \($0 + 1)" } ?? "Unclassified"
    }

    private func featureLabel(_ key: String) -> String {
        ["log_km": "Log distance", "overall_kmh": "Overall speed", "idle_share": "Idle share",
         "max_kmh": "Maximum speed", "log_min": "Log duration"][key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            NativeNotice(symbol: "scope", title: "Descriptive engineering", message: "Trip dots and per-trip distributions follow the history window. Pooled GPS diagrams, clustering, fitted models and forecasts use the full saved analytical window and are labelled below. These observations do not establish causes.", tint: NativeTheme.blue)
            engineCard
            cycleCard
            bandsCard
            accelerationCard
            rpaCard
            clusterCard
            silhouetteCard
            durationCard
            commuteCard
            soakCard
            correlationsCard
            forecastCard
            weeklyCard
            monthlyCard
        }
        .task(id: revision) {
            let values = snapshot.trips
            let anchor = snapshot.latestTrip?.start
            let filtered = await Task.detached(priority: .userInitiated) {
                values.filter { window.contains($0.start, anchor: anchor) }
            }.value
            guard !Task.isCancelled else { return }
            trips = filtered
            performanceTrips = filtered.compactMap(\.performance)
        }
    }

    private var engineCard: some View {
        let engine = trips.compactMap(\.engineMinutes)
        let engineHours = engine.isEmpty ? nil : engine.reduce(0, +) / 60
        let idle = trips.compactMap(\.idleMinutes)
        let distance = trips.compactMap(\.correctedDistanceKM)
        return NativeCard(title: "Engine-time exposure", symbol: "engine.combustion") {
            HStack(alignment: .top) {
                NativeMetric(title: "Engine time", value: NativeFormat.number(engineHours, digits: 1), unit: "h", caption: "\(engine.count) trips with engine-time values")
                NativeMetric(title: "Idling", value: NativeFormat.number(idle.isEmpty ? nil : idle.reduce(0, +) / 60, digits: 1), unit: "h", caption: "Recorded idle time")
            }
            if let engineHours, engineHours > 0, distance.count == trips.count, engine.count == trips.count, !distance.isEmpty {
                LabeledContent("Corrected km / engine hour", value: NativeFormat.number(distance.reduce(0, +) / engineHours, digits: 1)).font(.subheadline)
            }
            LabeledContent("Median GPS stop density", value: "\(NativeFormat.number(LabMath.quantile(performanceTrips.compactMap { LabMath.valid($0.stopsPerKM) }, 0.5), digits: 2)) stops/km").font(.subheadline)
            LabeledContent("Median GPS acceleration demand", value: "\(LabMath.number(LabMath.quantile(performanceTrips.compactMap { LabMath.valid($0.rpa) }, 0.5))) m/s² RPA").font(.subheadline)
            Text("Engine hours use moving + idle time, rather than calendar trip duration. A low distance per engine hour may reflect congestion and journey mix.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var cyclePoints: [LabPoint] {
        performanceTrips.compactMap { trip in
            guard let overall = LabMath.valid(trip.overallSpeedKMH), let maximum = LabMath.valid(trip.maxSpeedKMH) else { return nil }
            return LabPoint(id: trip.id, x: overall, y: maximum, series: name(trip.cluster),
                            detail: "\(trip.startText ?? "Date unavailable") · \(NativeFormat.number(trip.km, digits: 1)) km", tripID: trip.id)
        }
    }
    private var cycleCard: some View {
        NativeCard(title: "Drive-cycle context", symbol: "gauge.with.dots.needle.50percent") {
            LabXYChart(points: cyclePoints + referencePoints, xTitle: "Overall km/h incl. stops", yTitle: "Maximum km/h", snapshot: snapshot)
            Text("Colours identify saved trip types and WLTC reference phases. Laboratory cycle values give context; they are not targets, route equivalents or a measure of engine capability.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var referencePoints: [LabPoint] {
        (performance?.wltc ?? []).compactMap { phase in
            guard let average = phase.averageSpeedKMH, let maximum = phase.maxSpeedKMH else { return nil }
            return LabPoint(id: "reference-\(phase.phase)", x: average, y: maximum,
                            series: "WLTC reference", detail: phase.phase)
        }
    }

    private var bandsCard: some View {
        NativeCard(title: "Time in speed bands", symbol: "chart.bar.xaxis") {
            Picker("GPS trip group", selection: $speedGroup) {
                Text("All GPS trips").tag(-1)
                ForEach(profiles, id: \.cluster) { Text($0.name ?? "Group").tag($0.cluster) }
            }.pickerStyle(.menu)
            LabBarChart(values: bandValues, unit: "% of GPS sample time")
            Text("Full saved window. Pooled shares are time-weighted over retained GPS samples; trips without routes are excluded. ‘Stopped’ is below 5 km/h. Coarse GPS may under-represent brief stops and peaks.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var bandValues: [LabCategory] {
        guard let labels = performance?.speedBands?.bands else { return [] }
        let shares = speedGroup == -1 ? performance?.speedBands?.share : performance?.bandsByCluster?.first { $0.cluster == speedGroup }?.share
        return labels.indices.compactMap { index in
            guard let shares, shares.indices.contains(index), let value = LabMath.valid(shares[index]) else { return nil }
            return LabCategory(label: labels[index], value: value * 100)
        }
    }

    private var accelerationCard: some View {
        NativeCard(title: "Speed × acceleration occupancy", symbol: "square.grid.3x3") {
            if let density = performance?.speedAcceleration {
                LabHeatmap(columns: edgeLabels(density.speedEdges ?? [], digits: 0),
                           rows: edgeLabels(density.accelerationEdges ?? [], digits: 2),
                           cells: densityCells(density), unit: "minutes")
            } else { Text("Retained route samples are needed for this diagram.").font(.subheadline).foregroundStyle(.secondary) }
            Text("Full saved GPS window; intensity uses a logarithmic colour scale. Speed is reconstructed and smoothed from breadcrumbs; timestamps may be distributed within a minute. Accelerations are heavily low-pass estimates, not measured throttle/braking telemetry or peak acceleration.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func edgeLabels(_ edges: [Double?], digits: Int) -> [String] {
        guard edges.count >= 2 else { return [] }
        return (0..<(edges.count - 1)).map { "\(NativeFormat.number(edges[$0], digits: digits))–\(NativeFormat.number(edges[$0 + 1], digits: digits))" }
    }
    private func densityCells(_ density: SpeedAccelerationDensity) -> [LabHeatCell] {
        (density.seconds ?? []).enumerated().flatMap { column, values in
            values.enumerated().map { row, seconds in
                LabHeatCell(column: column, row: row, value: seconds.map { $0 / 60 })
            }
        }
    }

    private var rpaCard: some View {
        NativeCard(title: "Acceleration demand by trip type", symbol: "waveform.path") {
            LabSpreadChart(rows: rpaDistributions, unit: "RPA · m/s²")
            Text("Filtered trips with GPS-derived RPA. RPA = Σ speed × positive acceleration × time ÷ distance. Whiskers show the observed minimum and maximum. Compare similar trips within this archive; smoothing biases this proxy low and makes published high-frequency cycle comparisons inappropriate.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var rpaDistributions: [LabSpreadRow] {
        profiles.compactMap { profile in
            let values = performanceTrips.filter { $0.cluster == profile.cluster }.compactMap { LabMath.valid($0.rpa) }
            guard let low = values.min(), let high = values.max(), let q1 = LabMath.quantile(values, 0.25),
                  let median = LabMath.quantile(values, 0.5), let q3 = LabMath.quantile(values, 0.75) else { return nil }
            return LabSpreadRow(label: profile.name ?? "Group", low: low, q1: q1, median: median, q3: q3, high: high, detail: "\(values.count) routed trips")
        }
    }

    private var clusterCard: some View {
        NativeCard(title: "Trip archetypes · PCA", symbol: "point.3.connected.trianglepath.dotted") {
            Picker("Trip type", selection: $selectedCluster) {
                Text("All types").tag(-1)
                ForEach(profiles, id: \.cluster) { Text($0.name ?? "Group").tag($0.cluster) }
            }.pickerStyle(.menu)
            LabXYChart(points: pcaPoints, lines: loadingLines, xTitle: "PC1", yTitle: "PC2", snapshot: snapshot)
            if let variance = performance?.clusters?.explainedVariance, variance.count >= 2 {
                Text("Saved PCA variance: PC1 \(NativeFormat.percent(variance[0])); PC2 \(NativeFormat.percent(variance[1])). The scatter follows your history filter; fitted axes use the full saved window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Profiles and feature directions") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(profiles, id: \.cluster) { profile in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name ?? "Group").font(.subheadline.weight(.semibold))
                            Text("\(profile.trips.map(String.init) ?? "Unknown") trips · \(NativeFormat.percent(profile.distanceShare)) of corrected distance")
                            Text("Median \(NativeFormat.number(profile.km, digits: 1)) km · \(NativeFormat.number(profile.minutes)) min · \(NativeFormat.number(profile.overallSpeedKMH, digits: 1)) km/h overall · \(NativeFormat.percent(profile.idleShare)) idle")
                        }.font(.caption)
                    }
                    ForEach((performance?.clusters?.loadings ?? [:]).keys.sorted(), id: \.self) { feature in
                        let values = performance?.clusters?.loadings?[feature] ?? []
                        Text("\(featureLabel(feature)): \(values.map { NativeFormat.number($0, digits: 2) }.joined(separator: ", "))")
                            .font(.caption)
                    }
                }.padding(.top, 8)
            }.font(.subheadline)
            Text("K-means uses standardized log-distance, overall speed, idle share, maximum speed and log-duration. Names follow cluster medians. PCA directions are scaled only for display; a trip type is not a driver grade.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var pcaPoints: [LabPoint] {
        performanceTrips.filter { selectedCluster == -1 || $0.cluster == selectedCluster }.compactMap { trip in
            guard let x = LabMath.valid(trip.pc1), let y = LabMath.valid(trip.pc2) else { return nil }
            return LabPoint(id: trip.id, x: x, y: y, series: name(trip.cluster), detail: trip.startText ?? "", tripID: trip.id)
        }
    }
    private var loadingLines: [LabPoint] {
        let reach = max(1, pcaPoints.map { hypot($0.x, $0.y) }.max() ?? 1) * 0.55
        return (performance?.clusters?.loadings ?? [:]).keys.sorted().flatMap { key -> [LabPoint] in
            guard let vector = performance?.clusters?.loadings?[key], vector.count >= 2,
                  let x = LabMath.valid(vector[0]), let y = LabMath.valid(vector[1]) else { return [] }
            return [LabPoint(id: key + "-origin", x: 0, y: 0, series: featureLabel(key)),
                    LabPoint(id: key + "-end", x: x * reach, y: y * reach, series: featureLabel(key), detail: "Scaled PCA feature direction")]
        }
    }

    private var silhouetteCard: some View {
        NativeCard(title: "How well do groups separate?", symbol: "chart.bar") {
            LabBarChart(values: (performance?.clusters?.silhouette ?? [:]).keys.sorted().compactMap { key in
                guard let nested = performance?.clusters?.silhouette?[key], let value = LabMath.valid(nested) else { return nil }
                return LabCategory(label: "k = \(key)", value: value, series: Int(key) == performance?.clusters?.k ? "Used by model" : "Alternative")
            }, unit: "silhouette")
            Text("Full saved clustering window. Higher silhouette means stronger geometric separation under these features. It does not establish physical vehicle modes, and the chosen k may prioritize interpretable trip types.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var durationCard: some View {
        NativeCard(title: "Distance and journey duration", symbol: "point.topleft.down.curvedto.point.bottomright.up") {
            Toggle("Logarithmic axes", isOn: $logarithmic).font(.subheadline)
            LabXYChart(points: durationPoints, lines: durationFit, bands: durationBands,
                       xTitle: "Corrected distance · km", yTitle: "duration · min", logarithmicX: logarithmic,
                       logarithmicY: logarithmic, snapshot: snapshot)
            if let model = performance?.powerLaw {
                Text("Saved fit: time ≈ exp(\(NativeFormat.number(model.intercept, digits: 2))) × distance^\(NativeFormat.number(model.exponent, digits: 2)); log-space R² \(NativeFormat.number(model.r2, digits: 2)); \(model.sampleCount.map(String.init) ?? "Unknown") fit trips.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Dots follow the selected window; the fit and 95% prediction band use the saved whole-history model, for trips at least 1 km and 2 minutes. The model is descriptive and conditional on distance calibration.")
                .font(.caption).foregroundStyle(.secondary)
            NavigationLink("Inspect flagged duration outliers") { outlierList }
                .font(.subheadline)
        }
    }
    private var durationPoints: [LabPoint] {
        let outliers = Set((performance?.powerLaw?.outliers ?? []).map(\.id))
        return performanceTrips.compactMap { trip in
            guard let km = trip.km, let minutes = trip.elapsedMinutes, km >= 1, minutes >= 2 else { return nil }
            return LabPoint(id: trip.id, x: km, y: minutes, series: outliers.contains(trip.id) ? "Flagged residual" : "Journeys",
                            detail: trip.startText ?? "", tripID: trip.id)
        }
    }
    private var durationFit: [LabPoint] {
        guard let band = performance?.powerLaw?.band, let distance = band.km, let fit = band.fit else { return [] }
        return distance.indices.compactMap { i in
            guard fit.indices.contains(i), let x = distance[i], let y = fit[i] else { return nil }
            return LabPoint(id: "fit-\(i)", x: x, y: y, series: "Saved fit")
        }
    }
    private var durationBands: [LabBand] {
        guard let band = performance?.powerLaw?.band, let x = band.km, let low = band.low, let high = band.high else { return [] }
        return x.indices.compactMap { i in
            guard low.indices.contains(i), high.indices.contains(i), let value = x[i], let lower = low[i], let upper = high[i], lower > 0 else { return nil }
            return LabBand(id: "band-\(i)", x: value, lower: lower, upper: upper)
        }
    }
    private var outlierList: some View {
        List {
            Section {
                Text("Saved full-window model. Flagged trips have an absolute internally studentized residual above 2.5. This is a review aid, not a diagnosis.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(performance?.powerLaw?.outliers ?? [], id: \.id) { outlier in
                if let trip = snapshot.trips.first(where: { $0.id == outlier.id }) {
                    NavigationLink { NativeTripDetailView(trip: trip, snapshot: snapshot) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(NativeFormat.date(AnalyticsDate.parse(outlier.startText), includeTime: true))
                            Text("\(NativeFormat.number(outlier.km, digits: 1)) km · \(NativeFormat.duration(outlier.minutes)) actual · \(NativeFormat.duration(outlier.expectedMinutes)) expected")
                            Text("Residual \(NativeFormat.number(outlier.studentizedResidual, digits: 2)) · \(NativeFormat.duration(outlier.idleMinutes)) idle")
                                .foregroundStyle(.secondary)
                        }.font(.caption)
                    }
                }
            }
        }.navigationTitle("Duration outliers").navigationBarTitleDisplayMode(.inline)
    }

    private var activeCommute: CommuteDirection? { commuteDirection == "to_work" ? performance?.commute?.toWork : performance?.commute?.toHome }
    private var commuteCard: some View {
        NativeCard(title: "Commute reliability", symbol: "clock.badge.checkmark") {
            Picker("Commute direction", selection: $commuteDirection) {
                Text("To work").tag("to_work"); Text("To home").tag("to_home")
            }.pickerStyle(.segmented)
            if let direction = activeCommute {
                HStack(alignment: .top) {
                    NativeMetric(title: "Typical", value: NativeFormat.number(direction.median), unit: "min", caption: "\(direction.n.map(String.init) ?? "Unknown") archived drives")
                    NativeMetric(title: "95th percentile", value: NativeFormat.number(direction.p95), unit: "min", caption: "Historical planning allowance")
                }
                LabSpreadChart(rows: commuteSpreads, unit: "minutes")
                Text("Departure time and middle 50%").font(.subheadline.weight(.semibold))
                LabXYChart(points: commuteSlotPoints, bands: commuteSlotBands, xTitle: "Departure hour · IST", yTitle: "minutes")
                Text("Median by weekday").font(.subheadline.weight(.semibold))
                LabBarChart(values: (direction.byWeekday ?? []).compactMap { row in
                    guard let weekday = row.weekday, LabMath.weekdays.indices.contains(weekday), let value = row.medianMinutes else { return nil }
                    return LabCategory(label: LabMath.weekdays[weekday], value: value)
                }, unit: "median min")
                LabeledContent("Planning-time index", value: NativeFormat.number(direction.planningTimeIndex, digits: 2)).font(.caption)
                LabeledContent("Buffer-time index", value: NativeFormat.number(direction.bufferTimeIndex, digits: 2)).font(.caption)
                Text("Full saved window, inferred Home/Work labels, at least eight trips per direction. Departure slots need two observations. Outer range is the 5th–95th percentile; no guarantee of future arrival. Planning index = P95/P5; buffer index = (P95−mean)/mean.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Not enough labelled journeys in this direction. Browse recurring journey timing in Patterns; this saved reliability model needs at least eight Home/Work trips.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
    private var commuteSpreads: [LabSpreadRow] {
        guard let direction = activeCommute else { return [] }
        let minutes = (direction.minutes ?? []).compactMap { LabMath.valid($0) }
        guard let low = direction.freeFlow, let high = direction.p95, let median = direction.median,
              let q1 = LabMath.quantile(minutes, 0.25), let q3 = LabMath.quantile(minutes, 0.75) else { return [] }
        return [LabSpreadRow(label: commuteDirection == "to_work" ? "To work" : "To home", low: low, q1: q1,
                             median: median, q3: q3, high: high, detail: "Outer line: historical P5–P95")]
    }
    private var commuteSlotPoints: [LabPoint] {
        (activeCommute?.bySlot ?? []).enumerated().compactMap { i, slot in
            guard let hour = slot.hour, let median = slot.medianMinutes else { return nil }
            return LabPoint(id: "slot-\(i)", x: hour, y: median, series: "Median",
                            detail: "\(slot.tripCount.map(String.init) ?? "Unknown") trips · IQR \(NativeFormat.number(slot.lowerQuartile))–\(NativeFormat.number(slot.upperQuartile)) min")
        }
    }
    private var commuteSlotBands: [LabBand] {
        (activeCommute?.bySlot ?? []).enumerated().compactMap { i, slot in
            guard let hour = slot.hour, let low = slot.lowerQuartile, let high = slot.upperQuartile else { return nil }
            return LabBand(id: "slot-band-\(i)", x: hour, lower: low, upper: high, series: "Middle 50%")
        }
    }

    private var soakCard: some View {
        NativeCard(title: "Time parked before a journey", symbol: "thermometer.medium") {
            LabBarChart(values: soakValues, unit: "trips", horizontal: true)
            if let cold = performance?.cold {
                LabeledContent("Long-soak proxy share", value: NativeFormat.percent(cold.coldShare)).font(.subheadline)
                LabeledContent("Short long-soak trips", value: cold.shortCold.map(String.init) ?? "Unavailable").font(.subheadline)
                LabeledContent("Distance on these trips", value: "\(NativeFormat.number(cold.shortColdKM, digits: 1)) km").font(.subheadline)
                Text("Full saved window. ‘Long-soak’ means at least \(NativeFormat.number(cold.thresholdHours)) hours parked; short means under 5 km. Coolant temperature is unavailable, so this is not measured engine temperature. The legacy classification also treats the first trip’s unknown soak as long.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var soakValues: [LabCategory] {
        guard let cold = performance?.cold, let labels = cold.labels, let counts = cold.counts else { return [] }
        return labels.indices.compactMap { i in
            guard counts.indices.contains(i), let count = counts[i] else { return nil }
            return LabCategory(label: labels[i], value: count)
        }
    }

    private var correlationsCard: some View {
        NativeCard(title: "What moves together?", symbol: "square.grid.3x3.square") {
            let labels = performance?.correlations?.labels ?? []
            if !labels.isEmpty {
                LabHeatmap(columns: labels, rows: labels, cells: correlationCells, signed: true, unit: "Spearman ρ")
            } else { Text("No saved correlation matrix is available.").font(.subheadline).foregroundStyle(.secondary) }
            Text("Full saved window. Blue is negative and amber positive; intensity follows absolute rank correlation. Missing values can change the sample for each pair. Correlation does not establish causation: longer trips also tend to be different routes and conditions.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var correlationCells: [LabHeatCell] {
        (performance?.correlations?.matrix ?? []).enumerated().flatMap { row, values in
            values.enumerated().map { column, value in LabHeatCell(column: column, row: row, value: row == column ? nil : value) }
        }
    }

    private var forecastCard: some View {
        NativeCard(title: "Odometer projection", symbol: "chart.line.uptrend.xyaxis") {
            Picker("Projection horizon", selection: $forecastDays) {
                Text("30 days").tag(30); Text("90 days").tag(90); Text("240 days").tag(240)
            }.pickerStyle(.segmented)
            LabXYChart(points: [], lines: forecastLines, bands: forecastBands, xTitle: "Date", yTitle: "odometer · km", timeAxis: true)
            if let forecast = performance?.forecast {
                LabeledContent("Saved recent pace", value: "\(NativeFormat.number(forecast.kmPerDay, digits: 1)) km/day").font(.subheadline)
                DisclosureGroup("Milestone windows") {
                    ForEach(Array((forecast.milestones ?? []).prefix(12).enumerated()), id: \.offset) { _, milestone in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(NativeFormat.number(milestone.km)) km · median \(milestone.medianDate ?? "Outside horizon")")
                            Text("Early \(milestone.early ?? "Outside horizon") · late \(milestone.late ?? "Outside horizon")").foregroundStyle(.secondary)
                        }.font(.caption).padding(.vertical, 4)
                    }
                }.font(.subheadline)
                Text("Saved projection, not live telemetry. The band is an 80% model interval under independent daily-distance assumptions from the recent \(forecast.windowDays.map(String.init) ?? "unknown") days. Weekday dependence, holidays and changing usage are not modelled; interval coverage has not been calibrated here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var forecastLines: [LabPoint] {
        let history: [LabPoint] = (performance?.forecast?.history ?? []).compactMap { value in
            guard let date = value.date, let km = value.value else { return nil }
            return LabPoint(id: "history-\(value.timestamp)", x: date.timeIntervalSince1970, y: km, series: "Reconstructed history")
        }
        let future: [LabPoint] = (performance?.forecast?.future ?? []).prefix(forecastDays).compactMap { value in
            guard let date = value.date, let km = value.mean else { return nil }
            return LabPoint(id: "future-\(value.day)", x: date.timeIntervalSince1970, y: km, series: "Projected mean")
        }
        return LabMath.bounded(Array(history.suffix(365)), maximum: 180) + LabMath.bounded(future, maximum: 180)
    }
    private var forecastBands: [LabBand] {
        (performance?.forecast?.future ?? []).prefix(forecastDays).compactMap { value in
            guard let date = value.date, let lower = value.lower, let upper = value.upper else { return nil }
            return LabBand(id: "future-band-\(value.day)", x: date.timeIntervalSince1970, lower: lower, upper: upper)
        }
    }
    private var weeklyCard: some View {
        NativeCard(title: "Weekly distance", symbol: "calendar.badge.clock") {
            LabXYChart(points: [], lines: weeklyPoints, xTitle: "Week ending", yTitle: "km", timeAxis: true)
            Text("Recorded weeks in the selected history window, labelled by Sunday. Partial weeks and collection gaps can reduce totals.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var weeklyPoints: [LabPoint] {
        LabMath.bounded((performance?.forecast?.weekly ?? []).compactMap { row in
            guard let date = row.date, let value = row.value, window.contains(date, anchor: snapshot.latestTrip?.start) else { return nil }
            return LabPoint(id: row.timestamp, x: date.timeIntervalSince1970, y: value, series: "Weekly distance")
        })
    }
    private var monthlyCard: some View {
        NativeCard(title: "Monthly operating trends", symbol: "chart.xyaxis.line") {
            Picker("Trend metric", selection: $trend) {
                ForEach(["Idle share", "Moving speed", "Engine hours", "Events / 1,000 km"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.menu)
            LabXYChart(points: monthlyPoints, lines: monthlyPoints, xTitle: "Month", yTitle: trend, timeAxis: true)
            Text("Whole-month saved aggregates for every month touched by the selected window; edge months include days outside the window. Idle and speed are trip medians; engine hours sum moving+idle time. Event rates use distance exposure. Route and season mix can explain changes.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var monthlyPoints: [LabPoint] {
        (performance?.monthly ?? []).compactMap { month in
            guard let date = LabMath.monthDate(month.month), window.containsMonth(date, anchor: snapshot.latestTrip?.start) else { return nil }
            let value: Double?
            switch trend {
            case "Moving speed": value = month.movingSpeedKMH
            case "Engine hours": value = month.engineHours
            case "Events / 1,000 km": value = month.km.flatMap { km in km > 0 ? month.events.map { $0 / km * 1000 } : nil }
            default: value = month.idleShare.map { $0 * 100 }
            }
            guard let value else { return nil }
            return LabPoint(id: month.month, x: date.timeIntervalSince1970, y: value, series: trend,
                            detail: "\(month.trips.map(String.init) ?? "Unknown") trips · \(NativeFormat.number(month.km)) km")
        }
    }
}
