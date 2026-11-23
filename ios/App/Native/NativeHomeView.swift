import SwiftUI
import Charts
import I20Core

struct NativeHomeView: View {
    let snapshot: AnalyticsSnapshot?
    let onSettings: () -> Void
    @EnvironmentObject private var sync: SyncCoordinator
    @EnvironmentObject private var folder: FolderAccess
    @State private var days = 7
    @State private var showRefuel = false
    @State private var pastRefuels: [Refuel] = []

    init(snapshot: AnalyticsSnapshot?, onSettings: @escaping () -> Void = {}) {
        self.snapshot = snapshot
        self.onSettings = onSettings
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heading
                    syncNotice
                    if let snapshot {
                        periodCard(snapshot)
                        if let last = snapshot.latestTrip {
                            NavigationLink {
                                NativeTripDetailView(trip: last, snapshot: snapshot)
                            } label: {
                                NativeCard(title: "Last drive", symbol: "steeringwheel") {
                                    NativeTripRow(trip: last, showsDate: true)
                                    Label("Open debrief", systemImage: "arrow.up.right").font(.subheadline.weight(.semibold)).foregroundStyle(NativeTheme.blue)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("lastDrive")
                        }
                        fuelCard(snapshot)
                    } else {
                        NativeEmptyState(symbol: "gauge.with.dots.needle.33percent", title: "Your briefing starts here", message: "Sync or rebuild your logbook to see your latest drives, fuel and running patterns. Existing records stay in your archive.")
                    }
                    quickAdd
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(NativeTheme.background)
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onSettings) { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("openSettings")
                }
            }
            .refreshable {
                if folder.writesAllowed && (Credentials.load() != nil || DebugHarness.active) { sync.syncNow() } else { sync.rebuild() }
                await sync.task?.value
            }
            .onChange(of: folder.writesAllowed) { _, allowed in if !allowed { showRefuel = false } }
            .sheet(isPresented: $showRefuel) {
                RefuelForm(model: RefuelFormModel(past: pastRefuels), book: folder.book) { sync.rebuild() }
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(snapshot?.overview.vehicle?.model ?? "Your car")
                .font(.subheadline.weight(.semibold)).foregroundStyle(NativeTheme.blue)
            Text("A clearer view of every drive.")
                .font(.title3.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            if let observed = snapshot?.overview.status?.asOf {
                Text("Vehicle last reported \(NativeFormat.date(observed, includeTime: true)) · IST")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var syncNotice: some View {
        if sync.state.running {
            HStack(spacing: 10) {
                ProgressView()
                Text(syncLabel).font(.subheadline)
                Spacer(minLength: 0)
            }
            .padding(16).background(NativeTheme.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityIdentifier("nativeSyncProgress")
        } else if let error = sync.state.error {
            NativeNotice(symbol: "exclamationmark.circle", title: "Sync needs attention", message: error)
        } else if let observed = snapshot?.overview.status?.asOf, Date().timeIntervalSince(observed) > 24 * 3600 {
            NativeNotice(symbol: "clock.badge.exclamationmark", title: "Older vehicle reading", message: "Your last vehicle reading is over a day old. The figures below are historical, not live vehicle status.")
        } else if snapshot != nil && snapshot?.overview.status?.asOf == nil {
            NativeNotice(symbol: "clock", title: "Vehicle timestamp unavailable", message: "There is no timestamped vehicle reading in this snapshot. Trip history can still be explored, but current fuel and vehicle status are not established.", tint: NativeTheme.blue)
        } else if !sync.state.issues.isEmpty {
            NativeNotice(symbol: "exclamationmark.circle", title: "Some records need review", message: "\(sync.state.issues.count) issue\(sync.state.issues.count == 1 ? "" : "s") reported. Open Data quality in Lab for collection and analysis status.")
        }
    }

    private var syncLabel: String {
        switch sync.state.step {
        case "login": return "Connecting to Bluelink…"
        case "collect": return "Archiving new drives…"
        default: return "Updating your briefing…"
        }
    }

    private func periodCard(_ snapshot: AnalyticsSnapshot) -> some View {
        let summary = snapshot.periodSummary(days: days, endingOn: Date())
        return NativeCard(title: "Your recent driving", symbol: "chart.bar.xaxis") {
            Picker("Period", selection: $days) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("briefingPeriod")

            HStack(alignment: .top, spacing: 16) {
                NativeMetric(title: "Distance", value: NativeFormat.number(summary.distanceKM, digits: 1), unit: summary.distanceKM == nil ? nil : "km", caption: "\(summary.tripCount) recorded drives")
                NativeMetric(title: "Time on the road", value: NativeFormat.duration(summary.elapsedMinutes), caption: "Recorded trip duration")
            }
            if summary.tripCount > 0 {
                Chart(summary.daily) { day in
                    if let km = day.distanceKM {
                        BarMark(x: .value("Date", day.date, unit: .day), y: .value("Distance, km", km))
                            .foregroundStyle(NativeTheme.blue.gradient)
                            .cornerRadius(3)
                    }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 130)
                .accessibilityLabel("Daily recorded distance for the past \(days) days")
                .accessibilityValue("\(NativeFormat.number(summary.distanceKM, digits: 1)) kilometres across \(summary.tripCount) drives")
                HStack(alignment: .top, spacing: 16) {
                    NativeMetric(title: "Idle share", value: NativeFormat.percent(summary.idleShare), caption: "Idle ÷ (moving + idle)")
                    NativeMetric(title: "Estimated fuel cost", value: NativeFormat.money(summary.estimatedFuelCost), caption: "Modelled for \(summary.fuelCostTripCount) of \(summary.tripCount) drives")
                }
                Text("Source: archived trip summaries. Fuel costs are estimates; uncollected drives are not included.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No recorded drives in the past \(days) days. Try a longer period or sync your logbook. Missing collection is not proof the car stayed parked.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func fuelCard(_ snapshot: AnalyticsSnapshot) -> some View {
        NativeCard(title: "Last reported fuel", symbol: "fuelpump") {
            HStack(alignment: .top, spacing: 16) {
                NativeMetric(title: "Gauge", value: NativeFormat.number(snapshot.overview.status?.fuelPercent), unit: snapshot.overview.status?.fuelPercent == nil ? nil : "%", caption: "Vehicle-reported reading")
                NativeMetric(title: "Range", value: NativeFormat.number(snapshot.overview.status?.rangeKM), unit: snapshot.overview.status?.rangeKM == nil ? nil : "km", caption: "Vehicle-reported estimate")
            }
            if let asOf = snapshot.overview.status?.asOf {
                Text("As of \(NativeFormat.date(asOf, includeTime: true)) IST. Range depends on driving conditions.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No timestamped vehicle reading is available yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var quickAdd: some View {
        Button {
            guard folder.writesAllowed else { return }
            if let book = folder.book { pastRefuels = (try? loadAll(Refuel.self, from: book).entries) ?? [] }
            showRefuel = true
        } label: {
            Label("Log a refuel", systemImage: "plus.circle.fill")
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent).tint(NativeTheme.action)
        .disabled(!folder.writesAllowed)
        .accessibilityIdentifier("quickRefuel")
        .accessibilityHint(folder.writesAllowed ? "Add a refuel to this archive." : "Enable archive changes in Settings to add a refuel.")
    }
}
