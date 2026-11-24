import SwiftUI
import MapKit

private enum NativeAtlasMode: String, CaseIterable, Identifiable {
    case routes = "Routes", speed = "Speed", departure = "Time", density = "Density"
    var id: String { rawValue }
}

/// An independent, native view of archived geography. No location tracking or vehicle calls occur here.
struct NativeAtlasView: View {
    let snapshot: AnalyticsSnapshot?
    let onSettings: () -> Void
    let focusHotspot: TrafficHotspot?
    @State private var fromDate: Date?
    @State private var throughDate: Date?
    @State private var mode: NativeAtlasMode = .routes
    @State private var data = NativeAtlasRenderData.empty
    @State private var building = false
    @State private var visible = false
    @State private var loadedSelection: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var progress = 0.0
    @State private var playing = false
    @State private var camera: MapCameraPosition = .automatic
    @State private var showFilters = false
    @State private var showDetails = false
    @State private var showPlaces = false
    @State private var showHotspots: Bool
    @State private var showParked = false
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(snapshot: AnalyticsSnapshot?, onSettings: @escaping () -> Void = {},
         initialRange: ClosedRange<Date>? = nil, focusHotspot: TrafficHotspot? = nil) {
        self.snapshot = snapshot
        self.onSettings = onSettings
        self.focusHotspot = focusHotspot
        _fromDate = State(initialValue: initialRange?.lowerBound)
        _throughDate = State(initialValue: initialRange?.upperBound)
        _showHotspots = State(initialValue: focusHotspot != nil)
    }

    private var bounds: ClosedRange<Date> {
        let calendar = AnalyticsDate.calendar
        let first = calendar.startOfDay(for: snapshot?.history.firstDate ?? Date())
        let last = calendar.startOfDay(for: snapshot?.history.lastDate ?? first)
        return min(first, last)...max(first, last)
    }
    private var selectedFrom: Date { max(bounds.lowerBound, min(bounds.upperBound, fromDate ?? bounds.lowerBound)) }
    private var selectedThrough: Date { max(selectedFrom, min(bounds.upperBound, throughDate ?? bounds.upperBound)) }
    private var visibleCount: Int { min(data.trips.count, max(0, Int(progress.rounded(.down)))) }
    private var cursorTrip: NativeTrip? { visibleCount > 0 ? data.trips[visibleCount - 1] : nil }
    private var selectionKey: String {
        "\(snapshot?.generationID ?? "none")|\(selectedFrom.timeIntervalSince1970)|\(selectedThrough.timeIntervalSince1970)"
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                // Reserve room for the full cursor card, including floating tab chrome.
                // Read-only notices reduce this height even on a regular portrait phone.
                let scrolling = dynamicTypeSize.isAccessibilitySize || verticalSizeClass == .compact || geometry.size.height < 780
                if scrolling {
                    ScrollView {
                        atlasContent(scrolling: true).padding(.bottom, 88)
                    }
                } else {
                    atlasContent(scrolling: false)
                }
            }
            .background(NativeTheme.background)
            .navigationTitle("Atlas").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { playing = false; onSettings() } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings").accessibilityIdentifier("openSettings")
                }
            }
            .sheet(isPresented: $showFilters) { filters }
            .sheet(isPresented: $showDetails) { mapDetails }
            .task(id: "\(selectionKey)|\(visible && phase == .active)") {
                guard visible && phase == .active else { building = false; return }
                guard loadedSelection != selectionKey else { return }
                await rebuildProjection()
            }
            .task(id: playing) {
                guard playing else { return }
                let step = max(0.02, Double(data.trips.count) / 50)
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                    guard !Task.isCancelled else { return }
                    progress = min(Double(data.trips.count), progress + step)
                    if visibleCount >= data.trips.count { playing = false; return }
                }
            }
            .onAppear { visible = true }
            .onDisappear { visible = false; playing = false }
            .onChange(of: phase) { _, phase in if phase != .active { playing = false } }
        }
    }

    private func atlasContent(scrolling: Bool) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(NativeFormat.date(selectedFrom)) – \(NativeFormat.date(selectedThrough))")
                            .font(.caption.weight(.medium))
                        Text("\(data.routedTripCount) routed / \(data.trips.count) archived drives")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("atlasRouteCount")
                    }
                    Spacer(minLength: 0)
                    Button { playing = false; showFilters = true } label: {
                        Image(systemName: "line.3.horizontal.decrease").frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel("Atlas date range and layers").accessibilityIdentifier("atlasFilters")
                }
                Picker("Map layer", selection: $mode) {
                    ForEach(NativeAtlasMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).accessibilityIdentifier("atlasMode")
                .onChange(of: mode) { _, _ in playing = false }
                atlasMap(scrolling: scrolling)
                playbackControls
                legend
                if let snapshot, let trip = cursorTrip {
                    NavigationLink {
                        NativeTripDetailView(trip: trip, snapshot: snapshot)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Drive at cursor").font(.caption).foregroundStyle(.secondary)
                                Text(NativeFormat.tripTitle(trip)).font(.subheadline.weight(.medium)).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption)
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("atlasCursorTrip")
                    .simultaneousGesture(TapGesture().onEnded { playing = false })
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
    }

    private func atlasMap(scrolling: Bool) -> some View {
        Map(position: $camera) {
            if mode == .density {
                ForEach(data.density) { cell in
                    let visits = cell.visits(through: visibleCount)
                    if visits > 0 {
                        MapCircle(center: CLLocationCoordinate2D(latitude: cell.latitude, longitude: cell.longitude),
                                  radius: max(70, data.densityCellSizeDegrees * 111_000 * 0.45))
                            .foregroundStyle(densityColor(visits).opacity(min(0.75, 0.25 + log1p(Double(visits)) / 8)))
                    }
                }
            } else {
                ForEach((mode == .speed ? data.speedLines : data.lines).filter { $0.tripIndex < visibleCount }) { line in
                    MapPolyline(coordinates: line.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                        .stroke(lineColor(line).opacity(mode == .routes ? 0.48 : 0.85), lineWidth: mode == .routes ? 2 : 3)
                }
            }
            if showPlaces {
                ForEach(Array((snapshot?.overview.places ?? []).prefix(12).enumerated()), id: \.offset) { _, place in
                    if let point = coordinate(place.latitude, place.longitude) {
                        Annotation(place.name, coordinate: point) {
                            Text(place.name).font(.caption2.weight(.semibold)).padding(5)
                                .background(.regularMaterial, in: Capsule())
                        }
                    }
                }
            }
            if showHotspots {
                ForEach(Array((snapshot?.overview.hotspots ?? []).prefix(12).enumerated()), id: \.offset) { index, hotspot in
                    if let point = coordinate(hotspot.latitude, hotspot.longitude) {
                        Annotation("Historical slow area \(index + 1)", coordinate: point) {
                            Image(systemName: "clock.fill").font(.caption).foregroundStyle(.white)
                                .padding(6).background(NativeTheme.amber, in: Circle())
                        }
                    }
                }
            }
            if showParked, let park = snapshot?.overview.status?.park, park.count >= 2,
               let point = coordinate(park[0], park[1]) {
                Annotation("Last reported parking location", coordinate: point) {
                    Image(systemName: "parkingsign.circle.fill").foregroundStyle(NativeTheme.blue).font(.title2)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .mapControls { MapCompass(); MapScaleView() }
        .frame(minHeight: scrolling ? 260 : 160, maxHeight: scrolling ? 260 : .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay {
            if building {
                ProgressView("Preparing archived routes…").padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            } else if data.routedTripCount == 0 {
                VStack(spacing: 8) {
                    Image(systemName: "map").font(.title2)
                    Text("No usable archived routes in this range").font(.subheadline.weight(.semibold))
                    Text("Trip summaries remain in Trips.").font(.caption)
                }.padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).padding()
            }
        }
        .accessibilityLabel("Historical map, \(visibleCount) of \(data.trips.count) archived drives at the cursor")
        .accessibilityIdentifier("atlasMap")
    }

    private var playbackControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Button {
                    if visibleCount >= data.trips.count { progress = min(1, Double(data.trips.count)) }
                    playing.toggle()
                } label: { Image(systemName: playing ? "pause.fill" : "play.fill").frame(minWidth: 44, minHeight: 44) }
                .buttonStyle(.borderedProminent).tint(NativeTheme.action)
                .disabled(data.trips.isEmpty || building || reduceMotion)
                .accessibilityLabel(playing ? "Pause time-lapse" : "Play time-lapse")
                .accessibilityIdentifier("atlasReplayPlay")
                Button {
                    playing = false
                    progress = max(0, progress - 1)
                } label: { Image(systemName: "backward.end.fill").frame(minWidth: 40, minHeight: 44) }
                .disabled(visibleCount == 0).accessibilityLabel("Previous archived drive")
                Button {
                    playing = false
                    progress = min(Double(data.trips.count), progress + 1)
                } label: { Image(systemName: "forward.end.fill").frame(minWidth: 40, minHeight: 44) }
                .disabled(visibleCount >= data.trips.count).accessibilityLabel("Next archived drive")
                Spacer(minLength: 0)
                Button { playing = false; fitRoutes() } label: {
                    Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right").frame(minHeight: 44)
                }.accessibilityIdentifier("atlasFit")
            }
            Slider(value: $progress, in: 0...max(1, Double(data.trips.count)), step: 1, onEditingChanged: { editing in
                if editing { playing = false }
            })
            .disabled(data.trips.isEmpty || building)
            .accessibilityLabel("Historical map time-lapse position").accessibilityIdentifier("atlasScrubber")
            Text(cursorTrip.map { "\(NativeFormat.date($0.start, includeTime: true)) · drive \(visibleCount) of \(data.trips.count)" } ?? "Start of selected archive range")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .accessibilityIdentifier("atlasReplayDate")
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 5) {
            switch mode {
            case .routes: Text("Archived route traces; darker overlaps show repeated coverage.")
            case .speed: Text("GPS-derived speed: blue <20 · teal 20–40 · amber 40–60 · orange 60+ km/h. Grey = unknown.")
            case .departure: Text("Departure in IST: purple 00–06 · blue 06–12 · teal 12–18 · amber 18–24.")
            case .density: Text("Adaptive grid: distinct archived trips per area, not live traffic. Darker cells mean more visits.")
            }
            Button {
                playing = false
                showDetails = true
            } label: {
                Label(data.sourceLineCount > data.lines.count || data.sourceSpeedLineCount > data.speedLines.count
                      ? "Display sampling and map details" : "Map data and quality", systemImage: "info.circle")
            }
            .frame(minHeight: 30).accessibilityIdentifier("atlasMapDetails")
            if reduceMotion { Text("Reduce Motion: use the scrubber and step buttons.") }
        }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var filters: some View {
        NavigationStack {
            Form {
                Section("Archive date range · IST") {
                    DatePicker("From", selection: Binding(get: { selectedFrom }, set: { value in
                        playing = false; fromDate = value
                        if value > selectedThrough { throughDate = value }
                    }), in: bounds, displayedComponents: .date)
                    .accessibilityIdentifier("atlasFromDate")
                    DatePicker("Through", selection: Binding(get: { selectedThrough }, set: { value in
                        playing = false; throughDate = value
                        if value < selectedFrom { fromDate = value }
                    }), in: bounds, displayedComponents: .date)
                    .accessibilityIdentifier("atlasThroughDate")
                    Button("All history") { fromDate = nil; throughDate = nil }
                        .accessibilityIdentifier("atlasAllHistory")
                }
                Section("Optional reference layers") {
                    Toggle("Inferred places", isOn: $showPlaces)
                    Toggle("Historical slow areas", isOn: $showHotspots)
                    Toggle("Last reported parking", isOn: $showParked)
                }
                Section {
                    Text("Place labels are inferred from archived endpoints. Slow areas are historical GPS-derived summaries. Parking is a past vehicle reading, not a live location.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let asOf = snapshot?.overview.status?.asOf { Text("Vehicle reading: \(NativeFormat.date(asOf, includeTime: true)) IST").font(.footnote) }
                }
            }
            .environment(\.timeZone, AnalyticsDate.calendar.timeZone)
            .environment(\.calendar, AnalyticsDate.calendar)
            .navigationTitle("Atlas filters").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showFilters = false } } }
        }
    }

    private var mapDetails: some View {
        NavigationStack {
            Form {
                Section("Selected archive") {
                    LabeledContent("Archived drives", value: "\(data.trips.count)")
                    LabeledContent("Usable routed drives", value: "\(data.routedTripCount)")
                    LabeledContent("Retained GPS points", value: "\(data.pointCount)")
                    LabeledContent("Recorded distance", value: "\(NativeFormat.number(InsightStatistics.completeSum(data.trips.map(\.distanceKM)), digits: 1)) km")
                }
                Section("Display budget") {
                    LabeledContent("Route sections shown / available", value: "\(data.lines.count) / \(data.sourceLineCount)")
                    LabeledContent("Speed runs shown / available", value: "\(data.speedLines.count) / \(data.sourceSpeedLineCount)")
                    LabeledContent("Density cells", value: "\(data.density.count)")
                    Text("Large ranges use a deterministic sample of up to 450 route sections or 600 speed runs. Each section uses at most 160 original points. Counts and date filters still include the full selected trip history. Narrow the range or open a trip for its detailed trace.")
                    Text("The density grid adapts to the selected geographic extent (at most 600 cells). A trip counts only once per cell, so repeated GPS samples do not inflate its visit count.")
                }
                Section("Quality and playback") {
                    Text("Original gaps, invalid coordinates, non-increasing timestamps and coordinate jumps remain disconnected. Simplified lines are approximate, not verified roads. GPS speed is estimated, not sensor telemetry.")
                    Text("Time-lapse adds archived journeys in chronological order and compresses long date gaps. It is not a recording of continuous vehicle location. Playback stops when this screen disappears or the app leaves the foreground; it does no work while paused.")
                    Text("Map tiles may need network access. Route and trip data are read locally; no device location permission is requested.")
                }
            }
            .navigationTitle("Map evidence").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showDetails = false } } }
        }
    }

    private func rebuildProjection() async {
        playing = false
        building = true
        data = .empty
        progress = 0
        let capturedSelection = selectionKey
        let trips = snapshot?.tripRange(from: selectedFrom, through: selectedThrough) ?? []
        let worker = Task.detached(priority: .userInitiated) { NativeAtlasRenderData.build(trips: trips) }
        let projected = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        guard !Task.isCancelled else { return }
        data = projected
        progress = Double(projected.trips.count)
        building = false
        loadedSelection = capturedSelection
        if let focusHotspot, let point = coordinate(focusHotspot.latitude, focusHotspot.longitude) {
            camera = .region(MKCoordinateRegion(center: point, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))
        } else { fitRoutes() }
    }

    private func fitRoutes() {
        guard let lat = data.latitudeBounds, let lon = data.longitudeBounds else { camera = .automatic; return }
        camera = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (lat.lowerBound + lat.upperBound) / 2,
                                          longitude: (lon.lowerBound + lon.upperBound) / 2),
            span: MKCoordinateSpan(latitudeDelta: min(170, max(0.01, (lat.upperBound - lat.lowerBound) * 1.15)),
                                   longitudeDelta: min(359, max(0.01, (lon.upperBound - lon.lowerBound) * 1.15)))))
    }
    private func coordinate(_ latitude: Double?, _ longitude: Double?) -> CLLocationCoordinate2D? {
        guard let latitude, let longitude, latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    private func lineColor(_ line: NativeAtlasLine) -> Color {
        switch mode {
        case .speed:
            switch line.speedBand { case .some(0): return .blue; case .some(1): return .teal; case .some(2): return NativeTheme.amber; case .some(3): return .orange; default: return .gray }
        case .departure:
            return [NativeTheme.purple, NativeTheme.blue, NativeTheme.teal, NativeTheme.amber][line.departureBand]
        default: return NativeTheme.blue
        }
    }
    private func densityColor(_ visits: Int) -> Color { visits >= 5 ? NativeTheme.amber : NativeTheme.blue }
}
