import SwiftUI
import MapKit

private enum NativeTripFilter: String, CaseIterable, Identifiable {
    case all = "All drives"
    case routed = "With route"
    case short = "Under 5 km"
    case long = "30 km or more"
    var id: String { rawValue }

    func includes(_ trip: NativeTrip) -> Bool {
        switch self {
        case .all: return true
        case .routed: return trip.hasRoute
        case .short: return trip.distanceKM.map { $0 < 5 } ?? false
        case .long: return trip.distanceKM.map { $0 >= 30 } ?? false
        }
    }
}

struct NativeTripsView: View {
    let snapshot: AnalyticsSnapshot?
    let onSettings: () -> Void
    @State private var search = ""
    @State private var filter: NativeTripFilter = .all
    @EnvironmentObject private var sync: SyncCoordinator

    init(snapshot: AnalyticsSnapshot?, onSettings: @escaping () -> Void = {}) {
        self.snapshot = snapshot
        self.onSettings = onSettings
    }

    private var filteredTrips: [NativeTrip] {
        (snapshot?.trips ?? []).filter { trip in
            filter.includes(trip) && (search.isEmpty ||
                NativeFormat.tripTitle(trip).localizedCaseInsensitiveContains(search) ||
                trip.day.localizedCaseInsensitiveContains(search) ||
                NativeFormat.date(trip.start).localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let snapshot {
                    Section {
                        archiveSummary(snapshot)
                        NavigationLink { NativeTripActivityView(snapshot: snapshot) } label: {
                            Label("Driving activity", systemImage: "calendar")
                        }.accessibilityIdentifier("openDrivingActivity")
                    }
                }
                Section {
                    Picker("Show", selection: $filter) {
                        ForEach(NativeTripFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .accessibilityIdentifier("tripFilter")
                } footer: {
                    Text("Archived drives, newest first. Missing routes keep their trip summaries.")
                }
                if let snapshot, !filteredTrips.isEmpty {
                    Section("\(filteredTrips.count) recorded drive\(filteredTrips.count == 1 ? "" : "s")") {
                        ForEach(filteredTrips) { trip in
                            NavigationLink {
                                NativeTripDetailView(trip: trip, snapshot: snapshot)
                            } label: {
                                NativeTripRow(trip: trip, showsDate: true)
                                    .padding(.vertical, 6)
                            }
                            .accessibilityIdentifier("trip-\(trip.id)")
                        }
                    }
                } else {
                    Section {
                        NativeEmptyState(symbol: "point.bottomleft.forward.to.point.topright.scurvepath", title: snapshot == nil ? "No trip archive loaded" : "No matching drives", message: search.isEmpty && filter == .all ? "Sync your logbook to explore individual journeys and their recorded summaries." : "Try a different filter, place name or date. Search stays on this device.")
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(NativeTheme.background)
            .navigationTitle("Trips")
            .searchable(text: $search, prompt: "Place or date")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onSettings) { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings").accessibilityIdentifier("openSettings")
                }
            }
            .refreshable {
                if Credentials.load() != nil || DebugHarness.active { sync.syncNow() } else { sync.rebuild() }
                await sync.task?.value
            }
        }
    }
    private func archiveSummary(_ snapshot: AnalyticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                NativeMetric(title: "Odometer", value: NativeFormat.number(snapshot.overview.status?.odometer), unit: snapshot.overview.status?.odometer == nil ? nil : "km", caption: "Last vehicle reading")
                NativeMetric(title: "Archived distance", value: NativeFormat.number(snapshot.overview.totals?.km), unit: snapshot.overview.totals?.km == nil ? nil : "km", caption: "Includes model distance correction")
            }
            DisclosureGroup("Archive overview") {
                VStack(spacing: 9) {
                    LabeledContent("Recorded drives", value: "\(snapshot.trips.count)")
                    LabeledContent("Recorded trip time", value: NativeFormat.duration(snapshot.overview.totals?.hours.map { $0 * 60 }))
                    LabeledContent("Idle share", value: NativeFormat.percent(snapshot.overview.totals?.idleShare))
                    LabeledContent("Distance / odometer coverage", value: NativeFormat.percent(snapshot.overview.totals?.coverage))
                    LabeledContent("Routes retained", value: snapshot.overview.totals?.routedTrips.map(String.init) ?? "Unavailable")
                    Text("\(snapshot.overview.totals?.firstDay ?? "Unknown start") to \(snapshot.overview.totals?.lastDay ?? "unknown end"). Coverage is distance coverage, not proof every day was collected.")
                        .font(.caption).foregroundStyle(.secondary)
                }.font(.subheadline).padding(.top, 8)
            }.font(.subheadline)
        }.padding(.vertical, 4)
    }

}

struct NativeTripRow: View {
    let trip: NativeTrip
    var showsDate = true

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                Text(NativeFormat.tripTitle(trip)).font(.headline).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: trip.hasRoute ? "map" : "list.bullet.rectangle")
                    .font(.subheadline).foregroundStyle(NativeTheme.blue).accessibilityHidden(true)
            }
            if showsDate {
                Text(NativeFormat.date(trip.start, includeTime: true)).font(.caption).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { distanceLabel; timeLabel; idleLabel }
                VStack(alignment: .leading, spacing: 5) { distanceLabel; timeLabel; idleLabel }
            }
            .font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var distanceLabel: some View {
        Label(trip.distanceKM.map { "\(NativeFormat.number($0, digits: 1)) km" } ?? "Distance unavailable", systemImage: "road.lanes")
    }
    private var timeLabel: some View { Label(NativeFormat.duration(trip.elapsedMinutes), systemImage: "clock") }
    private var idleLabel: some View {
        let share = trip.idleShare
        return Text(share.map { "\(NativeFormat.percent($0)) idle" } ?? "Idle unavailable")
    }
}

struct NativeTripDetailView: View {
    let trip: NativeTrip
    let snapshot: AnalyticsSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(NativeFormat.tripTitle(trip)).font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(NativeFormat.date(trip.start, includeTime: true)) · IST")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                summaryCard
                NativeTripReplayView(trip: trip, generationID: snapshot.generationID)
                fuelCard
                comparisonCard
                NativeNotice(symbol: "info.circle", title: "Understand the source", message: "Trip time includes moving and idling. Fuel use and cost are model estimates, not a fuel-flow measurement. Archived GPS points cannot establish precise acceleration or live driving conditions.", tint: NativeTheme.blue)
            }
            .padding(16)
        }
        .background(NativeTheme.background)
        .navigationTitle("Drive debrief")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("tripDetail")
    }

    private var summaryCard: some View {
        NativeCard(title: "Recorded trip summary", symbol: "gauge.with.dots.needle.50percent") {
            HStack(alignment: .top, spacing: 16) {
                NativeMetric(title: "Distance", value: NativeFormat.number(trip.distanceKM, digits: 1), unit: trip.distanceKM == nil ? nil : "km", caption: "Provider-reported")
                NativeMetric(title: "Elapsed", value: NativeFormat.duration(trip.elapsedMinutes), caption: "Timestamps when available")
            }
            Divider()
            HStack(alignment: .top, spacing: 16) {
                NativeMetric(title: "Moving time", value: NativeFormat.duration(trip.driveMinutes))
                NativeMetric(title: "Idle time", value: NativeFormat.duration(trip.idleMinutes))
            }
            HStack(alignment: .top, spacing: 16) {
                NativeMetric(title: "Moving speed", value: NativeFormat.number(trip.movingSpeedKMH, digits: 1), unit: trip.movingSpeedKMH == nil ? nil : "km/h", caption: "Excludes idle time")
                NativeMetric(title: "Provider events", value: trip.events.map(String.init) ?? "Unavailable", caption: "Combined event count")
            }
            HStack(alignment: .top, spacing: 16) {
                NativeMetric(title: "Top speed", value: NativeFormat.number(trip.maxSpeedKMH, digits: 1), unit: trip.maxSpeedKMH == nil ? nil : "km/h", caption: "Vehicle-reported trip maximum")
                NativeMetric(title: "Idle share", value: NativeFormat.percent(trip.idleShare), caption: "Moving + idle denominator")
            }
            if let events = trip.record.events, events.count >= 3 {
                DisclosureGroup("Provider event breakdown") {
                    VStack(spacing: 8) {
                        LabeledContent("Harsh braking", value: "\(events[0])")
                        LabeledContent("Rapid acceleration", value: "\(events[1])")
                        LabeledContent("Overspeed", value: "\(events[2])")
                    }.font(.subheadline).padding(.top, 8)
                }.font(.subheadline)
            }
            Text("These summaries describe operating conditions and provider-defined events. They are not a driver safety score.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fuelCard: some View {
        NativeCard(title: "Estimated fuel", symbol: "fuelpump") {
            HStack(alignment: .top, spacing: 16) {
                NativeMetric(title: "Consumption", value: NativeFormat.number(trip.estimatedFuelLitres, digits: 2), unit: trip.estimatedFuelLitres == nil ? nil : "L", caption: "Model estimate")
                NativeMetric(title: "Fuel cost", value: NativeFormat.money(trip.estimatedFuelCost), caption: "Model estimate")
            }
            if trip.estimatedFuelLitres == nil {
                Text("A usable refuel model is needed to estimate this drive’s consumption.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Estimated from the refuel model and trip conditions. An individual trip has no directly measured fuel consumption in this source.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var comparisonCard: some View {
        let comparison = snapshot.compare(trip)
        return NativeCard(title: "Comparable journeys", symbol: "arrow.left.arrow.right") {
            if comparison.isSupported {
                HStack(alignment: .top, spacing: 16) {
                    NativeMetric(title: "Earlier median", value: NativeFormat.duration(comparison.medianMinutes), caption: "\(comparison.tripCount) trips across \(comparison.dateCount) dates")
                    NativeMetric(title: "This drive", value: NativeFormat.duration(trip.elapsedMinutes), caption: comparisonDifference(comparison.differenceMinutes))
                }
                if let lower = comparison.lowerQuartileMinutes, let upper = comparison.upperQuartileMinutes {
                    Text("Middle half of earlier durations: \(NativeFormat.duration(lower))–\(NativeFormat.duration(upper)).")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Text("More evidence needed").font(.subheadline.weight(.semibold))
                Text(comparison.reason ?? "There are not enough earlier comparable journeys yet.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("How trips are matched") {
                Text(comparison.method + " These differences are descriptive, not proof of a driving improvement.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 5)
            }
            .font(.subheadline)
        }
    }

    private func comparisonDifference(_ minutes: Double?) -> String {
        guard let minutes else { return "Difference unavailable" }
        if abs(minutes) < 0.5 { return "Near the earlier median" }
        return "\(NativeFormat.number(abs(minutes), digits: 1)) min \(minutes > 0 ? "longer" : "shorter") than median"
    }
}
