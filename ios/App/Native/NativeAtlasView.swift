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
    @State private var progress = 0
    @State private var expanded = false
    @State private var draftRange: ClosedRange<Date> = Date.distantPast...Date.distantPast
    @State private var draftAllHistory = true
    @State private var playing = false
    @State private var camera: MapCameraPosition = .automatic
    @State private var lastCamera: MapCamera?
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
    private var visibleCount: Int { min(data.trips.count, max(0, progress)) }
    private var cursorTrip: NativeTrip? { visibleCount > 0 ? data.trips[visibleCount - 1] : nil }
    private var selectionKey: String {
        "\(snapshot?.generationID ?? "none")|\(selectedFrom.timeIntervalSince1970)|\(selectedThrough.timeIntervalSince1970)"
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let mapHeight = verticalSizeClass == .compact
                    ? max(180, min(300, geometry.size.height - 32))
                    : max(340, min(500, geometry.size.height * 0.65))
                if expanded && !dynamicTypeSize.isAccessibilitySize && verticalSizeClass != .compact {
                    VStack(spacing: 12) {
                        atlasMap(height: nil)
                        playbackControls
                    }
                    .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
                } else {
                    ScrollView {
                        atlasContent(mapHeight: mapHeight)
                            .padding(.bottom, 88)
                    }
                }
            }
            .background(NativeTheme.background)
            .navigationTitle(expanded ? "Atlas · \(mode.rawValue)" : "Atlas").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { playing = false; onSettings() } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings").accessibilityIdentifier("openSettings")
                }
            }
            .toolbar(expanded && !dynamicTypeSize.isAccessibilitySize && verticalSizeClass != .compact ? .hidden : .visible, for: .tabBar)
            .sheet(isPresented: $showFilters, onDismiss: applyFilters) { filters }
            .sheet(isPresented: $showDetails) { mapDetails }
            .task(id: "\(selectionKey)|\(visible && phase == .active)") {
                guard visible && phase == .active else { building = false; return }
                guard loadedSelection != selectionKey else { return }
                await rebuildProjection()
            }
            .task(id: playing) {
                guard playing else { return }
                let step = NativeAtlasSelection.playbackStep(tripCount: data.trips.count)
                let interval = NativeAtlasSelection.playbackIntervalMS(tripCount: data.trips.count)
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(interval)) } catch { return }
                    guard !Task.isCancelled else { return }
                    progress = min(data.trips.count, progress + step)
                    if visibleCount >= data.trips.count { playing = false; return }
                }
            }
            .onAppear { visible = true }
            .onDisappear { visible = false; playing = false }
            .onChange(of: phase) { _, phase in if phase != .active { playing = false } }
        }
    }

    private func atlasContent(mapHeight: CGFloat) -> some View {
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
                    Button {
                        playing = false
                        draftRange = selectedFrom...selectedThrough
                        draftAllHistory = fromDate == nil && throughDate == nil
                        showFilters = true
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease").frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel("Atlas date range and layers").accessibilityIdentifier("atlasFilters")
                }
                Picker("Map layer", selection: $mode) {
                    ForEach(NativeAtlasMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).accessibilityIdentifier("atlasMode")
                .onChange(of: mode) { _, _ in playing = false }
                atlasMap(height: mapHeight)
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
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
    }

    private func atlasMap(height: CGFloat?) -> some View {
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
                    MapPolyline(line.polyline)
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
        .onMapCameraChange(frequency: .onEnd) { context in lastCamera = context.camera }
        .mapStyle(.standard(elevation: .flat))
        .mapControls { MapCompass(); MapScaleView() }
        .frame(minHeight: height ?? 160, maxHeight: height ?? .infinity)
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
        .overlay(alignment: .bottomTrailing) {
            if !dynamicTypeSize.isAccessibilitySize && verticalSizeClass != .compact {
                Button {
                    playing = false
                    if camera.positionedByUser, let lastCamera { camera = .camera(lastCamera) }
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel(expanded ? "Collapse map" : "Expand map")
                .accessibilityIdentifier("atlasExpandMap")
                .padding(12)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Historical map, \(visibleCount) of \(data.trips.count) archived drives at the cursor")
        .accessibilityIdentifier("atlasMap")
    }

    private var playbackControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Button {
                    if visibleCount >= data.trips.count { progress = min(1, data.trips.count) }
                    playing.toggle()
                } label: { Image(systemName: playing ? "pause.fill" : "play.fill").frame(minWidth: 44, minHeight: 44) }
                .buttonStyle(.borderedProminent).tint(NativeTheme.action)
                .disabled(data.trips.count < 2 || building || reduceMotion)
                .accessibilityLabel(playing ? "Pause time-lapse" : "Play time-lapse")
                .accessibilityIdentifier("atlasReplayPlay")
                Button {
                    playing = false
                    progress = max(0, progress - 1)
                } label: { Image(systemName: "backward.end.fill").frame(minWidth: 40, minHeight: 44) }
                .disabled(visibleCount == 0).accessibilityLabel("Previous archived drive")
                Button {
                    playing = false
                    progress = min(data.trips.count, progress + 1)
                } label: { Image(systemName: "forward.end.fill").frame(minWidth: 40, minHeight: 44) }
                .disabled(visibleCount >= data.trips.count).accessibilityLabel("Next archived drive")
                Spacer(minLength: 0)
                Button { playing = false; fitRoutes() } label: {
                    Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right").frame(minHeight: 44)
                }.accessibilityIdentifier("atlasFit")
            }
            Slider(value: Binding(get: { Double(progress) }, set: { progress = min(data.trips.count, max(0, Int($0.rounded()))) }), in: 0...max(1, Double(data.trips.count)), step: 1, onEditingChanged: { editing in
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
        VStack(alignment: .leading, spacing: 8) {
            switch mode {
            case .routes:
                Text("Archived route traces; darker overlaps show repeated coverage.")
            case .speed:
                Text("GPS-derived speed · km/h")
                legendChips([("<20", .blue), ("20–40", .teal), ("40–60", NativeTheme.amber), ("60+", .orange), ("Unknown", .gray)])
            case .departure:
                Text("Departure hour · IST")
                legendChips([("00–06", NativeTheme.purple), ("06–12", NativeTheme.blue), ("12–18", NativeTheme.teal), ("18–24", NativeTheme.amber)])
            case .density:
                Text("Distinct archived drives per area · stronger tint means more visits")
                legendChips([("1–4 drives", NativeTheme.blue), ("5+ drives", NativeTheme.amber)])
            }
            if showPlaces || showHotspots || showParked {
                Text("Reference layers: places and slow areas use all history; parking uses the latest saved reading.")
                    .accessibilityIdentifier("atlasReferenceScope")
            }
            Button {
                playing = false
                showDetails = true
            } label: {
                Label(data.sourceLineCount > data.lines.count || data.sourceSpeedLineCount > data.speedLines.count
                      ? "Display sampling and map details" : "Map data and quality", systemImage: "info.circle")
            }
            .frame(minHeight: 44).accessibilityIdentifier("atlasMapDetails")
            if reduceMotion { Text("Reduce Motion: use the scrubber and step buttons.") }
        }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func legendChips(_ items: [(String, Color)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.0) { label, color in
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 9, height: 9).accessibilityHidden(true)
                    Text(label)
                }
            }
        }
    }

    private var filters: some View {
        NavigationStack {
            Form {
                Section("Archive date range · IST") {
                    DatePicker("From", selection: Binding(get: { draftRange.lowerBound }, set: { value in
                        draftAllHistory = false
                        draftRange = NativeAtlasSelection.movingStart(to: value, in: draftRange, bounds: bounds)
                    }), in: bounds, displayedComponents: .date)
                    .accessibilityIdentifier("atlasFromDate")
                    DatePicker("Through", selection: Binding(get: { draftRange.upperBound }, set: { value in
                        draftAllHistory = false
                        draftRange = NativeAtlasSelection.movingEnd(to: value, in: draftRange, bounds: bounds)
                    }), in: bounds, displayedComponents: .date)
                    .accessibilityIdentifier("atlasThroughDate")
                    Button("All history") { draftAllHistory = true; draftRange = bounds }
                        .accessibilityIdentifier("atlasAllHistory")
                    Text("The date range is applied when you close these filters.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Reference layers · independent of playback") {
                    Toggle("Inferred places", isOn: $showPlaces)
                    Toggle("Historical slow areas", isOn: $showHotspots)
                    Toggle("Last reported parking", isOn: $showParked)
                }
                Section {
                    Text("Places and slow areas summarize all archived history, independently of the selected dates and playback position. Parking uses the latest saved vehicle reading; it is not a live location.")
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

    private func applyFilters() {
        if draftAllHistory { fromDate = nil; throughDate = nil }
        else {
            let range = NativeAtlasSelection.clamped(draftRange, to: bounds)
            fromDate = range.lowerBound
            throughDate = range.upperBound
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
        progress = projected.trips.count
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
