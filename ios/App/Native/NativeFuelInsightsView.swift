import SwiftUI

/// The existing scenario entry stays immediate; historical fuel studies live alongside it natively.
struct NativeFuelScenarioView: View {
    let model: FuelModel?
    var snapshot: AnalyticsSnapshot? = nil
    @State private var section = "Scenario"
    @State private var distance = 200.0
    @State private var cityShare = 0.6
    @State private var idleMinutes = 60.0
    @State private var price = 100.0

    private var scenario: FuelScenario {
        FuelScenario(distanceKM: distance, cityShare: cityShare, idleHours: idleMinutes / 60, pricePerLitre: price)
    }
    var body: some View {
        VStack(spacing: 0) {
            Picker("Fuel study", selection: $section) {
                Text("Scenario").tag("Scenario"); Text("History & model").tag("History")
            }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.vertical, 10)
                .accessibilityIdentifier("fuelStudyPicker")
            if section == "Scenario" { scenarioForm }
            else {
                ScrollView { NativeFuelHistoryView(snapshot: snapshot).padding(16) }
                    .background(NativeTheme.background).accessibilityIdentifier("fuelHistoryScreen")
            }
        }
        .navigationTitle("Fuel scenario").navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fuelScenarioScreen")
    }
    private var scenarioForm: some View {
        Form {
            Section {
                Text("An illustrative week").font(.headline)
                Text("Adjust hypothetical inputs. Starting values are examples, not your driving history.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Your assumptions") {
                control("Distance", value: $distance, range: 0...1000, step: 10, display: "\(NativeFormat.number(distance)) km")
                control("City-distance share", value: $cityShare, range: 0...1, step: 0.05, display: NativeFormat.percent(cityShare))
                control("Engine idling", value: $idleMinutes, range: 0...600, step: 15, display: "\(NativeFormat.number(idleMinutes)) min")
                control("Fuel price", value: $price, range: 1...200, step: 1, display: "\(NativeFormat.money(price))/L")
            }
            Section("Model-based scenario") {
                if let estimate = scenario.estimate(using: model?.coef) {
                    LabeledContent("Fuel", value: "\(NativeFormat.number(estimate.totalLitres, digits: 1)) L")
                    LabeledContent("Of which idling", value: "\(NativeFormat.number(estimate.idleLitres, digits: 1)) L")
                    LabeledContent("Cost", value: NativeFormat.money(estimate.cost))
                    Text("Based on \(model?.intervalCount.map(String.init) ?? "an unknown number of") usable fill intervals. This is a conditional model calculation, not a forecast or guaranteed saving. Its uncertainty is not quantified here.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No usable fuel model is available. Log complete refuel intervals to enable estimates; no default consumption figures are substituted.").foregroundStyle(.secondary)
                }
            }
            Section("How this works") {
                Text("Fuel = city km × city L/100 km ÷ 100 + highway km × highway L/100 km ÷ 100 + idle hours × idle L/hour.")
                Text("City/highway is a whole-trip speed proxy. Weather, traffic, AC use, payload and operating-condition changes are unobserved. Inputs outside the observed mix can extrapolate poorly.")
                Text("Use scenarios when parked. Do not assume all traffic idling can safely be eliminated.")
            }.font(.footnote)
        }
    }
    private func control(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, display: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(title, value: display).font(.subheadline).monospacedDigit()
            Slider(value: value, in: range, step: step) { Text(title) }.accessibilityValue(display)
        }.padding(.vertical, 3)
    }
}

struct NativeFuelHistoryView: View {
    let snapshot: AnalyticsSnapshot?
    @State private var window: LabWindow = .all
    @State private var brand = "All brands"
    @State private var fillKind = "All fills"
    @State private var parameter = "city_l100"
    @State private var monthlyMetric = "Cost"
    @State private var gaugeMetric = "Fuel %"
    @State private var rows: [FillRow] = []
    @State private var tankLines: [LabPoint] = []
    @State private var tankBands: [LabBand] = []
    @State private var gaugePoints: [LabPoint] = []
    private var fuel: FuelAnalytics? { snapshot?.fuel }
    private var model: FuelModel? { fuel?.model }
    private var anchor: Date? {
        [snapshot?.latestObservationDate, AnalyticsDate.parse(fuel?.totals?.lastFill)].compactMap { $0 }.max()
    }
    private var revision: String { "\(snapshot?.generationID ?? "absent")|\(window.rawValue)|\(brand)|\(fillKind)|\(gaugeMetric)" }
    private struct FillRow: Identifiable, Sendable {
        let id: Int
        let fill: FuelFill
        let date: Date
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            if fuel == nil {
                NativeEmptyState(symbol: "drop", title: "Fuel evidence is not ready", message: "A usable saved fuel analysis needs archived trips and complete refuel intervals. The scenario remains available when a valid model exists; nothing is invented for missing history.")
            } else {
                LabWindowPicker(selection: $window, anchor: anchor, anchorLabel: "latest archived observation or fill")
                NativeNotice(symbol: "drop", title: "Three different kinds of fuel evidence", message: "Refuel payments and quantities are logged observations, some values may be imputed. Interval economy uses reconstructed distance. Trip costs, fuel attribution and tank paths are model estimates; a gauge reading remains a separate provider observation.", tint: NativeTheme.blue)
                totalsCard
                fillCard
                priceCard
                brandCard
                calibrationCard
                economyCard
                highwayCard
                missingCard
                posteriorCard
                posteriorCorrelationCard
                fittedCard
                evidenceCard
                NativeFuelModelTrustCard(model: model)
                monthlyCard
                sharesCard
                tripCostCard
                tankCard
                gaugeCard
            }
        }
        .task(id: revision) { await prepareHistory() }
    }

    private var totalsCard: some View {
        NativeCard(title: "Saved fuel window", symbol: "drop.fill") {
            HStack(alignment: .top) {
                NativeMetric(title: "Full-to-full economy", value: NativeFormat.number(fuel?.totals?.economyKMPL, digits: 1), unit: "km/L", caption: "Usable reconstructed intervals")
                NativeMetric(title: "Attributed cost", value: NativeFormat.money(fuel?.totals?.modelCostPerKM), unit: "/ km", caption: "Modelled consumption over archived km")
            }
            Text("\(fuel?.totals?.fills.map(String.init) ?? "Unknown") fills · \(fuel?.totals?.firstFill ?? "unknown") to \(fuel?.totals?.lastFill ?? "unknown"). These summary/model values retain the entire saved fit window; filters below change historical charts, not the fitted coefficients.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var fillCard: some View {
        NativeCard(title: "Refuels, one by one", symbol: "fuelpump") {
            HStack {
                Picker("Brand", selection: $brand) {
                    Text("All brands").tag("All brands")
                    ForEach(Array(Set((fuel?.fills ?? []).compactMap(\.brand))).sorted(), id: \.self) { Text($0).tag($0) }
                }
                Picker("Fill classification", selection: $fillKind) {
                    ForEach(["All fills", "Full / inferred full", "Other / unknown"], id: \.self) { Text($0).tag($0) }
                }
            }.pickerStyle(.menu).font(.caption)
            LabXYChart(points: fillPoints(rate: false), xTitle: "Fill date", yTitle: "litres", timeAxis: true)
            let known = rows.compactMap { $0.fill.amount }
            LabeledContent("Logged payments in selection", value: NativeFormat.money(known.isEmpty ? nil : known.reduce(0, +))).font(.subheadline)
            Text("\(rows.count) fills; \(known.count) amounts known. Fill classification may use the legacy volume heuristic where full-tank status was not recorded. Above-rated fills are review flags, not proof of a larger safe usable tank. Do not top off to a chart threshold.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var priceCard: some View {
        NativeCard(title: "Price paid per litre", symbol: "indianrupeesign") {
            LabXYChart(points: fillPoints(rate: true), xTitle: "Fill date", yTitle: "₹ / litre", timeAxis: true, includeZeroY: false)
            Text("‘Price-flagged’ is a relative-price heuristic, not verified fuel grade. Geography, timing and imputation affect prices. Brand differences in these logs are not a causal fuel-economy comparison.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func fillPoints(rate: Bool) -> [LabPoint] {
        rows.compactMap { row in
            guard let y = LabMath.valid(rate ? row.fill.rate : row.fill.litres) else { return nil }
            let fill = row.fill
            let classification = rate ? (fill.premium == true ? "Price-flagged" : "Other prices") : (fill.brim == true ? "Full / inferred full" : "Other / unknown")
            return LabPoint(id: "fill-\(row.id)", x: row.date.timeIntervalSince1970, y: y, series: classification,
                            detail: "\(fill.station ?? "Station not recorded") · \(fill.brand ?? "Brand unknown") · \(NativeFormat.money(fill.amount)) · odometer ≈ \(NativeFormat.number(fill.odometerKM)) km\(fill.imputed.map { " · " + $0 + " imputed" } ?? "")")
        }
    }
    private var brandCard: some View {
        NativeCard(title: "Brand ledger · selected fills", symbol: "list.bullet.rectangle") {
            let grouped = Dictionary(grouping: rows, by: { $0.fill.brand ?? "Not recorded" })
            ForEach(grouped.keys.sorted(), id: \.self) { key in
                let group = grouped[key] ?? []
                let litres = group.compactMap { $0.fill.litres }
                let payments = group.compactMap { $0.fill.amount }
                VStack(alignment: .leading, spacing: 4) {
                    Text(key).font(.subheadline.weight(.semibold))
                    Text("\(group.count) fills · \(NativeFormat.number(litres.isEmpty ? nil : litres.reduce(0, +), digits: 1)) L · \(NativeFormat.money(payments.isEmpty ? nil : payments.reduce(0, +)))")
                    Text("Median price \(NativeFormat.money(LabMath.quantile(group.compactMap { $0.fill.rate }, 0.5)))/L · known quantities only")
                        .foregroundStyle(.secondary)
                }.font(.caption)
            }
        }
    }
    private var calibrationCard: some View {
        NativeCard(title: "Distance calibration", symbol: "ruler") {
            LabeledContent("Additive correction", value: "\(NativeFormat.number(fuel?.calibration?.delta, digits: 3)) km / trip").font(.subheadline)
            LabeledContent("Typical anchor residual", value: "\(NativeFormat.number(fuel?.calibration?.residualSD, digits: 2)) km").font(.subheadline)
            LabXYChart(points: calibrationPoints, lines: identity(calibrationPoints), xTitle: "Logged odometer · km", yTitle: "rebuilt odometer · km", includeZeroY: false, includeZeroX: false)
            Text("Full saved calibration window; \(fuel?.calibration?.n.map(String.init) ?? "unknown") logged odometer anchors. Raw and corrected reconstruction are compared with the same anchors. The constant-per-trip correction is a model assumption, not an independently proven provider mechanism.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var calibrationPoints: [LabPoint] {
        (fuel?.calibration?.points ?? []).enumerated().flatMap { i, point -> [LabPoint] in
            guard let x = point.loggedKM else { return [] }
            let rows: [(String, Double?)] = [("Raw reconstruction", point.rebuiltRawKM), ("Corrected reconstruction", point.rebuiltKM)]
            return rows.compactMap { name, y in y.map {
                LabPoint(id: "anchor-\(i)-\(name)", x: x, y: $0, series: name,
                         detail: "\(point.date ?? "") · residual \(NativeFormat.number(point.residualKM, digits: 2)) km")
            } }
        }
    }
    private func identity(_ points: [LabPoint]) -> [LabPoint] {
        let values = points.flatMap { [$0.x, $0.y] }.filter(\.isFinite)
        guard let minimum = values.min(), let maximum = values.max() else { return [] }
        return [LabPoint(id: "identity-low", x: minimum, y: minimum, series: "Identity"),
                LabPoint(id: "identity-high", x: maximum, y: maximum, series: "Identity")]
    }

    private var intervals: [FuelInterval] {
        (fuel?.intervals ?? []).filter { window.contains(AnalyticsDate.parse($0.to), anchor: anchor) }
    }
    private var economyCard: some View {
        NativeCard(title: "Full-to-full interval economy", symbol: "chart.xyaxis.line") {
            LabXYChart(points: intervalPoints(highway: false), xTitle: "Interval end", yTitle: "km / litre", timeAxis: true)
            Text("Interval distance is reconstructed/calibrated, fuel comes from logged fills. Blue/amber categories separate usable intervals and review flags. Unknown values remain absent; excluded intervals are not quietly folded into the model fit.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Interval ledger") {
                ForEach(Array(intervals.suffix(40).enumerated()), id: \.offset) { _, interval in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(interval.from ?? "Unknown") → \(interval.to ?? "Unknown")").fontWeight(.medium)
                        Text("\(NativeFormat.number(interval.km, digits: 1)) km · \(NativeFormat.number(interval.litres, digits: 1)) L · \(NativeFormat.number(interval.kmpl, digits: 1)) km/L")
                        Text("\(interval.status?.replacingOccurrences(of: "_", with: " ") ?? "Status unknown") · \(interval.trips.map(String.init) ?? "Unknown") trips")
                            .foregroundStyle(.secondary)
                    }.font(.caption).padding(.vertical, 4)
                }
                if intervals.count > 40 { Text("Latest 40 intervals listed; charts sample the full selected interval set.").font(.caption2) }
            }.font(.subheadline)
        }
    }
    private var highwayCard: some View {
        NativeCard(title: "Economy and journey mix", symbol: "road.lanes") {
            LabXYChart(points: intervalPoints(highway: true), xTitle: "Highway-proxy distance · %", yTitle: "km / litre")
            Text("Each point is a refuel interval. Highway mix uses the saved whole-trip average-speed threshold of \(NativeFormat.number(fuel?.constants?.highwayThresholdKMH)) km/h. This proxy does not measure actual road class; association with economy is not a causal speed recommendation.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func intervalPoints(highway: Bool) -> [LabPoint] {
        intervals.enumerated().compactMap { i, interval in
            let x = highway ? interval.highwayShare.map { $0 * 100 } : AnalyticsDate.parse(interval.to)?.timeIntervalSince1970
            guard let x, let y = LabMath.valid(interval.kmpl) else { return nil }
            return LabPoint(id: "interval-\(i)", x: x, y: y, series: interval.status == "ok" ? "Usable" : "Needs review",
                            detail: "\(interval.from ?? "") to \(interval.to ?? "") · \(NativeFormat.number(interval.km, digits: 1)) km · \(NativeFormat.number(interval.litres, digits: 1)) L · \(interval.status ?? "Unknown status")")
        }
    }
    private var missingCard: some View {
        NativeCard(title: "Gaps and reconciliation", symbol: "exclamationmark.bubble") {
            let missing = (fuel?.missing ?? []).filter { window.contains(AnalyticsDate.parse($0.to), anchor: anchor) }
            if missing.isEmpty { Text("No model-flagged missing-fill intervals in this window. This is not proof the log is complete.").font(.subheadline).foregroundStyle(.secondary) }
            ForEach(Array(missing.suffix(20).enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(row.from ?? "Unknown") → \(row.to ?? "Unknown")").font(.subheadline.weight(.medium))
                    Text("Logged \(NativeFormat.number(row.loggedLitres, digits: 1)) L · model expects \(NativeFormat.number(row.neededLitres, digits: 1)) L · difference \(NativeFormat.number(row.unloggedLitres, digits: 1)) L")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("These are model review flags, not confirmed missing purchases. The legacy eligibility rules include a type-approval reference heuristic. Check full/partial status, odometers and omitted fills in Garage before drawing conclusions. Tank history deliberately breaks where fuel cannot be reconstructed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var posteriorCard: some View {
        NativeCard(title: "Consumption coefficients · prior and posterior", symbol: "function") {
            Picker("Consumption coefficient", selection: $parameter) {
                Text("City L/100 km").tag("city_l100"); Text("Highway L/100 km").tag("hwy_l100"); Text("Idle L/hour").tag("idle_lph")
            }.pickerStyle(.menu)
            LabXYChart(points: [], lines: densityPoints, xTitle: parameter == "idle_lph" ? "litres / hour" : "litres / 100 km", yTitle: "density")
            Text("Full saved fit. The prior is the starting assumption; the posterior combines that assumption with usable full-to-full intervals. Density height is not a probability for one exact coefficient value. Curves that barely move can indicate weak evidence.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Posterior mean", value: NativeFormat.number(coefficient(parameter, from: model?.coef), digits: 3)).font(.subheadline)
            LabeledContent("Posterior standard deviation", value: NativeFormat.number(coefficient(parameter, from: model?.sd), digits: 3)).font(.subheadline)
        }
    }
    private func coefficient(_ key: String, from coefficients: FuelCoefficients?) -> Double? {
        switch key { case "hwy_l100": coefficients?.highwayL100; case "idle_lph": coefficients?.idleLPH; default: coefficients?.cityL100 }
    }
    private var densityPoints: [LabPoint] {
        guard let curve = model?.curves?[parameter], let x = curve.x else { return [] }
        return [("Prior", curve.prior ?? []), ("Posterior", curve.posterior ?? [])].flatMap { name, values in
            x.indices.compactMap { i in
                guard values.indices.contains(i), let horizontal = x[i], let density = values[i] else { return nil }
                return LabPoint(id: "\(name)-\(i)", x: horizontal, y: density, series: name)
            }
        }
    }
    private var posteriorCorrelationCard: some View {
        NativeCard(title: "Can the model separate its effects?", symbol: "square.grid.3x3") {
            LabHeatmap(columns: ["City", "Highway", "Idling"], rows: ["City", "Highway", "Idling"],
                       cells: (model?.posteriorCorrelation ?? []).enumerated().flatMap { row, values in
                values.enumerated().map { column, value in LabHeatCell(column: column, row: row, value: row == column ? nil : value) }
            }, signed: true, unit: "posterior correlation")
            Text("High absolute coefficient correlation means several consumption explanations can fit the same intervals. Many trips do not replace independent refuel intervals or varied operating mix. Parameter uncertainty is conditional on this model and reconstruction.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var fitPoints: [LabPoint] {
        (model?.fitted ?? []).enumerated().compactMap { i, row in
            guard let actual = row.actualLitres, let predicted = row.predictedLitres else { return nil }
            return LabPoint(id: "fit-\(i)", x: actual, y: predicted, series: "Training intervals",
                            detail: "\(row.from ?? "") to \(row.to ?? "") · residual \(NativeFormat.number(predicted - actual, digits: 2)) L")
        }
    }
    private var fittedCard: some View {
        NativeCard(title: "Recorded vs fitted interval litres", symbol: "scope") {
            LabXYChart(points: fitPoints, lines: identity(fitPoints), xTitle: "Recorded litres", yTitle: "fitted litres")
            LabeledContent("In-sample R²", value: NativeFormat.number(model?.r2, digits: 3)).font(.subheadline)
            Text("Training-fit diagnostics use the same intervals as fitting; a close fit is not held-out accuracy. Chronological and nested leave-one-out errors below provide separate consumption-fit checks.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var evidenceCard: some View {
        NativeCard(title: "Noise-scale sensitivity", symbol: "waveform.path") {
            LabXYChart(points: [], lines: evidencePoints, xTitle: "Noise scale · litres", yTitle: "log evidence", includeZeroY: false)
            LabeledContent("Selected noise scale", value: "\(NativeFormat.number(model?.sigmaLitres, digits: 2)) L").font(.subheadline)
            Text("Full saved model; empirical-Bayes marginal likelihood chooses the noise scale. A broad evidence peak suggests the data do not pin it down sharply. Noise is reselected within validation folds.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var evidencePoints: [LabPoint] {
        guard let evidence = model?.evidence, let sigma = evidence.sigma, let logEvidence = evidence.logEvidence else { return [] }
        return sigma.indices.compactMap { i in
            guard logEvidence.indices.contains(i), let x = sigma[i], let y = logEvidence[i] else { return nil }
            return LabPoint(id: "evidence-\(i)", x: x, y: y, series: "Log evidence")
        }
    }

    private var monthlyCard: some View {
        NativeCard(title: "Payments vs consumed fuel", symbol: "calendar") {
            Picker("Monthly comparison", selection: $monthlyMetric) { Text("Cost").tag("Cost"); Text("Litres").tag("Litres") }.pickerStyle(.segmented)
            LabXYChart(points: monthlyPoints, lines: monthlyPoints, xTitle: "Month", yTitle: monthlyMetric == "Cost" ? "₹" : "litres", timeAxis: true)
            Text("Whole saved months touched by the date window, including partial edge-month days. Payments/filled litres are logged cash or purchases; model-attributed cost/litres belong to journeys. Purchases and consumption need not line up within a month. Brand/fill-type filters apply only to the fill ledger above.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var monthlyPoints: [LabPoint] {
        (fuel?.monthly ?? []).filter { window.containsMonth($0.date, anchor: anchor) }.flatMap { month -> [LabPoint] in
            guard let date = month.date else { return [] }
            let pairs: [(String, Double?)] = monthlyMetric == "Cost" ? [("Payments", month.spend), ("Attributed consumption", month.estimatedCost)]
                : [("Filled litres", month.litres), ("Estimated burn", month.estimatedLitres)]
            return pairs.compactMap { name, value in value.map { LabPoint(id: "\(month.month)-\(name)", x: date.timeIntervalSince1970, y: $0, series: name) } }
        }
    }
    private var sharesCard: some View {
        NativeCard(title: "Distance mix and fuel attribution", symbol: "chart.bar.xaxis") {
            LabBarChart(values: mixShares, unit: "%")
            LabeledContent("Estimated idle consumption", value: "\(NativeFormat.number(fuel?.totals?.idleLitres, digits: 1)) L").font(.subheadline)
            LabeledContent("Attributed idle cost", value: NativeFormat.money(fuel?.totals?.idleCost)).font(.subheadline)
            Text("Full saved model window. City fuel share includes modelled idling on city-proxy trips. It is not a controlled comparison, and idling cannot always safely be avoided.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var mixShares: [LabCategory] {
        let shares: [(String, Double?, String)] = [("City", fuel?.totals?.cityDistanceShare, "Distance"), ("City", fuel?.totals?.cityFuelShare, "Model fuel")]
        return shares.flatMap { label, value, series -> [LabCategory] in
            guard let value, value.isFinite else { return [] }
            return [LabCategory(label: label, value: value * 100, series: series), LabCategory(label: "Highway", value: (1 - value) * 100, series: series)]
        }
    }
    private var tripCostCard: some View {
        NativeCard(title: "Estimated cost per journey", symbol: "indianrupeesign.circle") {
            LabXYChart(points: tripCosts, xTitle: "Journey distance · km", yTitle: "estimated ₹", snapshot: snapshot)
            Text("Trip fuel is inferred from the consumption model and multiplied by the available fuel-price history. It is not a measured fuel-flow signal or a payment receipt. Select a plotted journey to inspect its actual archived trip record.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var tripCosts: [LabPoint] {
        (snapshot?.trips ?? []).compactMap { trip in
            guard window.contains(trip.start, anchor: anchor), let km = trip.correctedDistanceKM, let cost = trip.estimatedFuelCost else { return nil }
            return LabPoint(id: trip.id, x: km, y: cost, series: trip.fuel?.highway == true ? "Highway proxy" : "City proxy",
                            detail: "\(NativeFormat.date(trip.start, includeTime: true)) · \(NativeFormat.number(trip.estimatedFuelLitres, digits: 2)) L estimated", tripID: trip.id)
        }
    }
    private var tankCard: some View {
        NativeCard(title: "Estimated tank path", symbol: "fuelpump.circle") {
            LabXYChart(points: [], lines: tankLines, bands: tankBands, xTitle: "Archived time", yTitle: "estimated litres", timeAxis: true)
            Text("A reconstructed inventory, anchored by logged fills and inferred burn. The shaded ±1.96 standard-deviation band describes the saved model’s conditional uncertainty; it does not capture every missing fill, calibration error or operating change. Unknown stretches are disconnected. This is not a live fuel gauge.")
                .font(.caption).foregroundStyle(.secondary)
            Text("\(fuel?.tank?.gaps?.count ?? 0) unknown stretches in the full saved history. Tank capacity assumption: \(NativeFormat.number(fuel?.constants?.tankLitres, digits: 1)) L.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var gaugeCard: some View {
        NativeCard(title: "Provider fuel and range observations", symbol: "gauge.with.dots.needle.33percent") {
            Picker("Gauge metric", selection: $gaugeMetric) {
                Text("Fuel %").tag("Fuel %"); Text("Reported range").tag("Reported range")
            }.pickerStyle(.segmented)
            LabXYChart(points: gaugePoints, xTitle: "Observation time", yTitle: gaugeMetric == "Fuel %" ? "%" : "reported km", timeAxis: true)
            Text("Dots are archived provider observations, which may be stale, rounded or delayed. Range is the vehicle’s estimate, not a distance guarantee. Model percentage is shown separately when supplied; it does not replace the observed gauge. Gaps are not interpolated.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func prepareHistory() async {
        let fuel = fuel
        let selectedWindow = window, selectedBrand = brand, selectedKind = fillKind, selectedGauge = gaugeMetric
        let latest = anchor
        let prepared = await Task.detached(priority: .userInitiated) { () -> ([FillRow], [LabPoint], [LabBand], [LabPoint]) in
            let fills = (fuel?.fills ?? []).enumerated().compactMap { index, fill -> FillRow? in
                guard let date = AnalyticsDate.parse(fill.moment ?? fill.date), selectedWindow.contains(date, anchor: latest),
                      selectedBrand == "All brands" || fill.brand == selectedBrand else { return nil }
                let full = fill.brim == true
                guard selectedKind == "All fills" || (selectedKind == "Full / inferred full" ? full : !full) else { return nil }
                return FillRow(id: index, fill: fill, date: date)
            }
            let gaps: [(Date, Date)] = (fuel?.tank?.gaps ?? []).compactMap {
                guard let from = AnalyticsDate.parse($0.from), let to = AnalyticsDate.parse($0.to) else { return nil }
                return (from, to)
            }
            var lines: [LabPoint] = [], bands: [LabBand] = [], segment = 0
            var previous: Date?
            for (index, point) in (fuel?.tank?.points ?? []).enumerated() {
                guard let date = point.date, let litres = LabMath.valid(point.litres) else { segment += 1; previous = nil; continue }
                if let previous, gaps.contains(where: { $0.0 <= date && $0.1 >= previous }) { segment += 1 }
                previous = date
                guard selectedWindow.contains(date, anchor: latest) else { continue }
                let key = "tank-\(segment)"
                lines.append(LabPoint(id: "tank-\(index)", x: date.timeIntervalSince1970, y: litres, series: "Estimated tank", segment: key))
                if let sd = LabMath.valid(point.standardDeviationLitres), sd >= 0 {
                    bands.append(LabBand(id: "tank-band-\(index)", x: date.timeIntervalSince1970, lower: litres - 1.96 * sd, upper: litres + 1.96 * sd, segment: key))
                }
            }
            let savedGauge = fuel?.tank?.gauge ?? []
            let gauge = (savedGauge.isEmpty ? (fuel?.fuelLevel ?? []) : savedGauge).enumerated().flatMap { index, reading -> [LabPoint] in
                guard let date = reading.date, selectedWindow.contains(date, anchor: latest) else { return [] }
                if selectedGauge == "Reported range" {
                    return LabMath.valid(reading.rangeKM).map { [LabPoint(id: "range-\(index)", x: date.timeIntervalSince1970, y: $0, series: "Provider range")] } ?? []
                }
                var points: [LabPoint] = []
                if let value = LabMath.valid(reading.fuelPercent) { points.append(LabPoint(id: "gauge-\(index)", x: date.timeIntervalSince1970, y: value, series: "Observed gauge")) }
                if let value = LabMath.valid(reading.modelPercent) { points.append(LabPoint(id: "model-gauge-\(index)", x: date.timeIntervalSince1970, y: value, series: "Model estimate")) }
                return points
            }
            return (fills, LabMath.bounded(lines, maximum: 600), LabMath.bounded(bands, maximum: 400), LabMath.bounded(gauge, maximum: 300))
        }.value
        guard !Task.isCancelled else { return }
        rows = prepared.0; tankLines = prepared.1; tankBands = prepared.2; gaugePoints = prepared.3
    }
}

struct NativeFuelModelTrustCard: View {
    let model: FuelModel?
    var body: some View {
        NativeCard(title: "Does the fuel model generalise?", symbol: "checkmark.shield") {
            if let validation = model?.validation {
                Text(validation.scope).font(.caption).foregroundStyle(.secondary)
                validationBlock("Chronological holdout", result: validation.chronological)
                Divider()
                validationBlock("Nested leave-one-interval-out", result: validation.loo)
                if let caveat = validation.caveat { Text(caveat).font(.caption).foregroundStyle(.secondary) }
                if let bias = validation.biasDefinition { Text(bias).font(.caption).foregroundStyle(.secondary) }
                Text("Chronological tests train only on earlier intervals; nested holdouts repeat fitting inside each fold. Compare model and baseline on the same eligible observations. Small samples, correlated journeys, missing fills and changes in conditions limit how well either result transfers to the future.")
                    .font(.caption).foregroundStyle(.secondary)
                LabXYChart(points: holdoutPoints(validation.chronological), xTitle: "Held-out logged litres", yTitle: "predicted litres")
            } else {
                Text("Held-out validation is unavailable. A fitted coefficient or a good training fit alone does not establish predictive accuracy.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
    private func validationBlock(_ title: String, result: FuelValidationResult) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.subheadline.weight(.semibold))
            Text("\(result.predictions) model predictions · minimum \(result.minTrainIntervals) training intervals").font(.caption)
            LabeledContent("Model / baseline MAE", value: "\(NativeFormat.number(result.modelMAE, digits: 2)) / \(NativeFormat.number(result.baselineMAE, digits: 2)) L").font(.caption)
            LabeledContent("Model / baseline bias", value: "\(NativeFormat.number(result.modelBias, digits: 2)) / \(NativeFormat.number(result.baselineBias, digits: 2)) L").font(.caption)
            Text("Baseline predictions: \(result.baselinePredictions.map(String.init) ?? "unknown") · eligible: \(result.eligibleIntervals.map(String.init) ?? "unknown") · insufficient history: \(result.insufficientHistoryIntervals.map(String.init) ?? "unknown") · excluded dates: \(result.excludedDateIntervals.map(String.init) ?? "unknown")").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Method") { Text(result.method).font(.caption).textSelection(.enabled) }.font(.caption)
        }
    }
    private func holdoutPoints(_ result: FuelValidationResult) -> [LabPoint] {
        (result.predictionRows ?? []).enumerated().flatMap { index, row -> [LabPoint] in
            guard let actual = LabMath.valid(row.actualLitres) else { return [] }
            let detail = "\(row.from ?? "?") → \(row.to ?? "?") · trained on \(row.trainIntervals.map(String.init) ?? "unknown") earlier intervals"
            return [("Fuel model", row.predictedLitres), ("Baseline", row.baselineLitres)].compactMap { name, value in
                LabMath.valid(value).map { LabPoint(id: "holdout-\(index)-\(name)", x: actual, y: $0, series: name, detail: detail) }
            }
        }
    }
}
