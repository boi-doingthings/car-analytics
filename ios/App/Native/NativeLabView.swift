import SwiftUI

private enum NativeLabStudy: String, CaseIterable, Identifiable {
    case patterns = "Patterns"
    case performance = "Performance"
    var id: String { rawValue }
}

struct NativeLabView: View {
    let snapshot: AnalyticsSnapshot?
    var onSettings: () -> Void = {}
    @State private var study: NativeLabStudy = .patterns
    @State private var window: LabWindow = .quarter

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Text("Ask a question. Inspect the evidence.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    tools
                    if let snapshot {
                        LabWindowPicker(selection: $window, anchor: snapshot.latestTrip?.start)
                        Picker("Study", selection: $study) {
                            ForEach(NativeLabStudy.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("labStudyPicker")
                        if study == .patterns {
                            NativeDrivingPatternsView(snapshot: snapshot, window: window)
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("drivingPatternsScreen")
                        } else {
                            NativePerformanceInsightsView(snapshot: snapshot, window: window)
                                .accessibilityIdentifier("performanceInsightsScreen")
                        }
                    } else {
                        NativeEmptyState(symbol: "chart.xyaxis.line", title: "Your archive is the evidence", message: "Choose a logbook and rebuild its analysis to explore driving patterns and performance studies. You can still open the scenario tool and data-quality diagnostics above.")
                    }
                    NativeNotice(symbol: "scope", title: "Know what was measured", message: "Provider trip summaries and events are recorded data. GPS speed and acceleration are reconstructions from coarse archived samples. Fuel use, costs and future odometer values are estimates; differences do not establish causes.", tint: NativeTheme.blue)
                }.padding(16)
            }
            .background(NativeTheme.background)
            .navigationTitle("Lab")
            .accessibilityIdentifier("nativeLabScreen")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onSettings) { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings").accessibilityIdentifier("openSettings")
                }
            }
        }
    }

    private var tools: some View {
        HStack(alignment: .top, spacing: 12) {
            NavigationLink {
                NativeFuelScenarioView(model: snapshot?.fuel?.model, snapshot: snapshot)
            } label: {
                tool("Fuel & scenarios", detail: "History, model & what-if", symbol: "fuelpump")
            }.buttonStyle(.plain).accessibilityIdentifier("openFuelScenario")
            NavigationLink { NativeDataQualityView(snapshot: snapshot) } label: {
                tool("Data quality", detail: "Coverage & freshness", symbol: "checkmark.shield")
            }.buttonStyle(.plain).accessibilityIdentifier("openDataQuality")
        }
    }

    private func tool(_ title: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(NativeTheme.blue)
                Text(title).foregroundStyle(.primary)
            }
            .font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(14)
        .background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 18))
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
