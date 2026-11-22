import SwiftUI

struct NativeLabView: View {
    let snapshot: AnalyticsSnapshot?
    var onSettings: () -> Void = {}
    @EnvironmentObject private var sync: SyncCoordinator

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Ask a question. Inspect the evidence.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    NativeCard(title: "Engineering tools", symbol: "slider.horizontal.3") {
                        NavigationLink { NativeFuelScenarioView(model: snapshot?.fuel?.model) } label: {
                            tool("Fuel scenario", detail: "Explore distance, journey mix and idling", symbol: "function")
                        }.buttonStyle(.plain).accessibilityIdentifier("openFuelScenario")
                        Divider()
                        NavigationLink { NativeDataQualityView(snapshot: snapshot) } label: {
                            tool("Data quality", detail: "Coverage, freshness and model support", symbol: "checkmark.shield")
                        }.buttonStyle(.plain).accessibilityIdentifier("openDataQuality")
                        Divider()
                        NavigationLink { DashboardView().navigationTitle("Detailed analysis").navigationBarTitleDisplayMode(.inline) } label: {
                            tool("Detailed analysis", detail: "Open the existing interactive dashboard", symbol: "chart.xyaxis.line")
                        }.buttonStyle(.plain).accessibilityIdentifier("openDetailedAnalysis")
                    }
                    NativeCard(title: "Compare like with like", symbol: "arrow.left.arrow.right") {
                        Text("Open a trip to see how its duration compares with earlier journeys in the same direction, at a similar time and distance.")
                            .font(.subheadline)
                        Text("A baseline needs at least 10 earlier matched trips across 3 dates. Weather and traffic are unobserved; a difference does not establish a cause.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    modelEvidence
                    NativeNotice(symbol: "scope", title: "Know what was measured", message: "Trip times, distances and provider events are recorded data. Fuel per trip, costs and service arrival dates are estimates. Coarse archived GPS is not high-frequency vehicle telemetry.", tint: NativeTheme.blue)
                }.padding(16)
            }
            .background(NativeTheme.background)
            .navigationTitle("Lab")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onSettings) { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings").accessibilityIdentifier("openSettings")
                }
            }
        }
    }

    private func tool(_ title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).foregroundStyle(NativeTheme.blue).font(.title3).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 7).frame(minHeight: 44)
    }

    private var modelEvidence: some View {
        NativeCard(title: "Fuel model support", symbol: "point.3.connected.trianglepath.dotted") {
            if let model = snapshot?.fuel?.model {
                NativeMetric(title: "Usable fill intervals", value: model.intervalCount.map(String.init) ?? "Unavailable", caption: "Independent fuel observations; trip count is not the training sample size")
                if let count = model.intervalCount, count < 3 {
                    Text("Very little evidence. The model may largely reflect its starting assumptions.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                LabeledContent("Internal model error", value: "\(NativeFormat.number(model.leaveOneOutMAE, digits: 1)) L")
                LabeledContent("Simple baseline error", value: "\(NativeFormat.number(model.baselineMAE, digits: 1)) L")
                Text("These are internal leave-one-out diagnostics. Noise selection currently uses all intervals, so they are not independent validation. Use them to inspect the fit, not prove an improvement.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("The model needs usable full-to-full refuel intervals. You can explore recorded journeys while that history builds.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

struct NativeFuelScenarioView: View {
    let model: FuelModel?
    @State private var distance = 200.0
    @State private var cityShare = 0.6
    @State private var idleMinutes = 60.0
    @State private var price = 100.0

    private var scenario: FuelScenario {
        FuelScenario(distanceKM: distance, cityShare: cityShare, idleHours: idleMinutes / 60, pricePerLitre: price)
    }

    var body: some View {
        Form {
            Section {
                Text("An illustrative week")
                    .font(.headline)
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
                    Text("No usable fuel model is available. Log complete refuel intervals to enable estimates; no default consumption figures are substituted.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("How this works") {
                Text("Fuel = city km × city L/100 km ÷ 100 + highway km × highway L/100 km ÷ 100 + idle hours × idle L/hour.")
                Text("City/highway is currently a whole-trip speed proxy. The calculation does not account for a change in weather, traffic, AC use, payload or driving conditions. Inputs outside the observed operating mix may extrapolate poorly.")
                Text("Use scenarios when parked. Avoid treating all traffic idling as something you can safely eliminate.")
            }.font(.footnote)
        }
        .navigationTitle("Fuel scenario").navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("fuelScenarioScreen")
    }

    private func control(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, display: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(title, value: display).font(.subheadline).monospacedDigit()
            Slider(value: value, in: range, step: step) { Text(title) }
                .accessibilityValue(display)
        }.padding(.vertical, 3)
    }
}

struct NativeDataQualityView: View {
    let snapshot: AnalyticsSnapshot?
    @EnvironmentObject private var sync: SyncCoordinator

    var body: some View {
        List {
            Section("Freshness") {
                LabeledContent("Last collection", value: NativeFormat.date(sync.state.lastSync, includeTime: true))
                LabeledContent("Vehicle observation", value: NativeFormat.date(snapshot?.overview.status?.asOf, includeTime: true))
                LabeledContent("Published analysis", value: NativeFormat.date(sync.state.lastAnalysis, includeTime: true))
                Text("A recent analysis can be computed from older vehicle records. Collection time is not the time of a vehicle measurement.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Archive coverage") {
                LabeledContent("Recorded trips", value: snapshot.map { String($0.trips.count) } ?? "Unavailable")
                LabeledContent("Trips with route geometry", value: snapshot.map { String($0.trips.filter(\.hasRoute).count) } ?? "Unavailable")
                LabeledContent("Archived distance / odometer", value: NativeFormat.percent(snapshot?.overview.totals?.coverage))
                Text("Distance coverage does not prove every day was collected. A route may be incomplete even when geometry is present. Source GPS timestamps can be coarse.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let snapshot, let oldest = snapshot.trips.last?.start, let newest = snapshot.latestTrip?.start {
                Section("Recorded journey window") {
                    LabeledContent("First", value: NativeFormat.date(oldest))
                    LabeledContent("Latest", value: NativeFormat.date(newest))
                }
            }
            Section("Latest run") {
                if sync.state.running {
                    Label("Sync or analysis in progress", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                }
                if let error = sync.state.error { Text(error).foregroundStyle(.red) }
                if sync.state.issues.isEmpty {
                    Text(sync.state.lastAnalysis == nil ? "No completed analysis for this archive yet." : "No issues reported by the latest run. This is not a guarantee of complete data.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(sync.state.issues.enumerated()), id: \.offset) { _, issue in Text(issue).font(.footnote) }
                }
                Button("Rebuild from archive") { sync.rebuild() }.disabled(sync.state.running)
            }
            Section("Metric definitions") {
                Text("Recorded: provider-reported distance, moving/idle time, snapshots and logged payments.")
                Text("Derived: elapsed time, idle fraction and route coverage.")
                Text("Estimated: distance calibration, per-trip fuel/cost, inferred places and future maintenance dates.")
            }.font(.footnote)
        }
        .navigationTitle("Data quality").navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("dataQualityScreen")
    }
}
