import SwiftUI
import MapKit
import Charts

struct NativeTripReplayView: View {
    let trip: NativeTrip
    let generationID: String
    @State private var data = NativeTripReplayData.empty
    @State private var ready = false
    @State private var visible = false
    @State private var loadedRevision: String?
    @State private var seconds = 0.0
    @State private var playing = false
    @State private var replayLength = 20.0
    @State private var camera: MapCameraPosition = .automatic
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selected: NativeReplaySample? { data.sample(at: seconds) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            routeCard
            if data.canPlay {
                NativeCard(title: "Replay the archived samples", symbol: "play.circle") {
                    HStack {
                        Button {
                            if seconds >= data.duration { seconds = data.samples.first?.seconds ?? 0 }
                            playing.toggle()
                        } label: {
                            Label(playing ? "Pause replay" : "Play replay", systemImage: playing ? "pause.fill" : "play.fill")
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent).tint(NativeTheme.action)
                        .disabled(reduceMotion)
                        .accessibilityIdentifier("tripReplayPlay")
                        Spacer(minLength: 0)
                        Text(NativeFormat.duration(seconds / 60)).monospacedDigit().font(.subheadline)
                            .accessibilityIdentifier("tripReplayClock")
                    }
                    Slider(value: $seconds, in: 0...max(1, data.duration), onEditingChanged: { editing in
                        if editing { playing = false }
                    })
                    .accessibilityLabel("Trip replay position")
                    .accessibilityIdentifier("tripReplaySlider")
                    Picker("Replay length", selection: $replayLength) {
                        Text("10 sec").tag(10.0)
                        Text("20 sec").tag(20.0)
                        Text("40 sec").tag(40.0)
                    }.pickerStyle(.segmented)
                    .onChange(of: replayLength) { _, _ in playing = false }
                    if let selected {
                        HStack(alignment: .top, spacing: 16) {
                            NativeMetric(title: "GPS-derived speed", value: NativeFormat.number(selected.speedKMH), unit: selected.speedKMH == nil ? nil : "km/h", caption: "At the selected archived sample")
                            NativeMetric(title: "Sample time", value: NativeFormat.duration(selected.seconds / 60), caption: "Elapsed from first GPS timestamp")
                        }
                    }
                    Text(reduceMotion
                         ? "Reduce Motion is on. Use the scrubber to inspect samples without automatic movement."
                         : "Replay is compressed into the selected length. The marker jumps between actual retained samples; locations inside gaps are unknown.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                speedChart
                accelerationChart
            } else if trip.hasRoute {
                NativeNotice(symbol: "clock.badge.exclamationmark", title: "Replay timestamps unavailable", message: "The route can be displayed, but there are not enough valid increasing sample times to replay it. Trip summaries remain available.", tint: NativeTheme.blue)
            }
        }
        .task(id: "\(trip.id)|\(generationID)|\(visible && phase == .active)") {
            guard visible && phase == .active else { return }
            let revision = "\(trip.id)|\(generationID)"
            guard loadedRevision != revision else { return }
            playing = false
            ready = false
            data = .empty
            seconds = 0
            let worker = Task.detached(priority: .userInitiated) { NativeTripReplayData(trip: trip) }
            let value = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled else { return }
            data = value
            ready = true
            loadedRevision = revision
            seconds = value.samples.first?.seconds ?? 0
        }
        .task(id: playing) {
            guard playing else { return }
            let step = max(data.duration / (replayLength * 5), 0.2)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard !Task.isCancelled else { return }
                seconds = min(data.duration, seconds + step)
                if seconds >= data.duration { playing = false; return }
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false; playing = false }
        .onChange(of: phase) { _, phase in if phase != .active { playing = false } }
    }

    @ViewBuilder private var routeCard: some View {
        if !ready {
            ProgressView("Preparing archived route…").frame(maxWidth: .infinity).padding()
        } else if data.segments.contains(where: { $0.count >= 2 }) {
            NativeCard(title: "Archived route", symbol: "map") {
                Map(position: $camera) {
                    ForEach(Array(data.segments.enumerated()), id: \.offset) { segment in
                        MapPolyline(coordinates: segment.element.map(coordinate)).stroke(NativeTheme.blue, lineWidth: 4)
                    }
                    if let point = data.segments.first?.first {
                        Annotation("Start", coordinate: coordinate(point)) { pin("circle.fill", color: NativeTheme.blue) }
                    }
                    if let point = data.segments.last?.last {
                        Annotation("Finish", coordinate: coordinate(point)) { pin("flag.fill", color: NativeTheme.navy) }
                    }
                    if let selected {
                        Annotation("Selected archived sample", coordinate: CLLocationCoordinate2D(latitude: selected.latitude, longitude: selected.longitude)) {
                            Image(systemName: "car.side.fill").font(.subheadline)
                                .foregroundStyle(.white).padding(9).background(NativeTheme.action, in: Circle())
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat))
                .mapControls { MapCompass(); MapScaleView() }
                .frame(height: 270)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel("Archived route with disconnected samples kept separate")
                .accessibilityIdentifier("tripReplayMap")
                Button {
                    playing = false
                    camera = .automatic
                } label: { Label("Fit route", systemImage: "arrow.up.left.and.arrow.down.right").frame(minHeight: 44) }
                .font(.subheadline)
                Text("\(data.segments.reduce(0) { $0 + $1.count }) retained points. Invalid coordinates, non-increasing timestamps, and original gaps over 2 minutes or 2 km break the trace. Map tiles may need a connection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            NativeNotice(symbol: "map", title: "Route unavailable", message: "The trip summary is preserved, but these GPS points do not form a usable route. Summary speeds and provider events below remain available.", tint: NativeTheme.blue)
        }
    }

    private func coordinate(_ point: RouteCoordinate) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }

    private func pin(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol).font(.caption).foregroundStyle(.white).padding(6).background(color, in: Circle())
    }

    private var speedChart: some View {
        NativeCard(title: "GPS-derived speed profile", symbol: "speedometer") {
            let runs = runs(acceleration: false)
            if runs.isEmpty {
                Text("No usable speed samples for this route.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(runs) { run in
                        ForEach(run.samples) { sample in
                            if let speed = sample.speedKMH {
                                LineMark(x: .value("Elapsed minutes", sample.seconds / 60), y: .value("Estimated km/h", speed), series: .value("Contiguous section", run.id))
                                    .foregroundStyle(NativeTheme.blue).interpolationMethod(.linear)
                            }
                        }
                    }
                    if let selected {
                        RuleMark(x: .value("Selected minute", selected.seconds / 60)).foregroundStyle(NativeTheme.accent)
                        if let speed = selected.speedKMH {
                            PointMark(x: .value("Selected minute", selected.seconds / 60), y: .value("Estimated km/h", speed))
                                .foregroundStyle(NativeTheme.accent)
                        }
                    }
                }
                .chartXAxisLabel("Elapsed minutes").chartYAxisLabel("km/h")
                .chartXScale(domain: 0...max(1, data.duration / 60))
                .chartXSelection(value: chartSelection)
                .frame(height: 185)
                .accessibilityIdentifier("tripSpeedChart")
                Text("Tap or drag the chart or scrubber to select a retained sample. GPS speed uses coarse positions and reconstructed sample times; it can differ from the vehicle-reported average and top speed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var accelerationChart: some View {
        NativeCard(title: "Coarse acceleration estimate", symbol: "waveform.path", tint: NativeTheme.coral) {
            let runs = runs(acceleration: true)
            if runs.isEmpty {
                Text("Not enough contiguous timed speed pairs to estimate speed changes.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Chart {
                    RuleMark(y: .value("No speed change", 0)).foregroundStyle(.secondary.opacity(0.4))
                    ForEach(runs) { run in
                        ForEach(run.samples) { sample in
                            if let value = sample.accelerationMS2 {
                                LineMark(x: .value("Elapsed minutes", sample.seconds / 60), y: .value("Estimated m/s²", value), series: .value("Contiguous section", run.id))
                                    .foregroundStyle(NativeTheme.coral).interpolationMethod(.linear)
                            }
                        }
                    }
                    if let selected { RuleMark(x: .value("Selected minute", selected.seconds / 60)).foregroundStyle(NativeTheme.blue) }
                }
                .chartXAxisLabel("Elapsed minutes").chartYAxisLabel("m/s²")
                .chartXScale(domain: 0...max(1, data.duration / 60))
                .chartXSelection(value: chartSelection)
                .frame(height: 170)
                .accessibilityIdentifier("tripAccelerationChart")
                Text("Calculated as the change in GPS-derived speed divided by the sample-time gap, within intact sections only. This is a smoothed, coarse estimate—not accelerometer or CAN-bus telemetry. It cannot measure peak braking, 0–100 time or driver safety.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var chartSelection: Binding<Double?> {
        Binding(get: { seconds / 60 }, set: { value in
            guard let value else { return }
            playing = false
            seconds = min(data.duration, max(0, value * 60))
        })
    }

    private struct PlotRun: Identifiable {
        let id: Int
        let samples: [NativeReplaySample]
    }

    /// Preserve visual gaps for absent values. Limit chart drawing without inventing sample values.
    private func runs(acceleration: Bool) -> [PlotRun] {
        var result: [PlotRun] = [], current: [NativeReplaySample] = []
        var previousSegment: Int?
        func flush() {
            guard !current.isEmpty else { return }
            let stride = max(1, Int(ceil(Double(current.count) / 600)))
            var plotted = current.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
            if let last = current.last, plotted.last?.id != last.id { plotted.append(last) }
            result.append(PlotRun(id: result.count, samples: plotted))
            current = []
        }
        for sample in data.samples {
            let value = acceleration ? sample.accelerationMS2 : sample.speedKMH
            if value == nil || previousSegment != sample.segment { flush() }
            if value != nil { current.append(sample) }
            previousSegment = sample.segment
        }
        flush()
        return result
    }
}
