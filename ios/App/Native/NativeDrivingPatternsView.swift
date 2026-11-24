import SwiftUI

private enum NativeEventGrouping: String, CaseIterable, Identifiable {
    case type = "Event type"
    case weekday = "Weekday"
    var id: String { rawValue }
}

struct NativeDrivingPatternsView: View {
    let snapshot: AnalyticsSnapshot
    let window: LabWindow
    private var anchor: Date? { snapshot.latestTrip?.start }
    @State private var trips: [NativeTrip] = []
    private var revision: String { "\(snapshot.generationID)|\(snapshot.trips.count)|\(window.rawValue)" }
    @State private var chosenJourney = ""
    @State private var eventGrouping: NativeEventGrouping = .type
    @State private var eventExposure = PatternEventExposure(trips: [])
    private static let weekdayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    var body: some View {
        // One bounded section: avoid nested lazy layout omitting chart siblings from accessibility.
        VStack(alignment: .leading, spacing: 18) {
            NativeCard(title: "When you drive", symbol: "clock", tint: NativeTheme.indigo) {
                Text("\(trips.count) archived starts · India local time").font(.subheadline)
                LabHeatmap(columns: (0..<24).map { LabMath.hourLabel(Double($0)) }, rows: LabMath.weekdays,
                           cells: rhythm, unit: "trip starts")
                Text("Each square counts archived starts in that hour and weekday. A quiet square can also reflect a collection gap; it does not prove the car stayed parked.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            NativeCard(title: "Kilometres by weekday", symbol: "calendar", tint: NativeTheme.teal) {
                LabBarChart(values: weekdayDistance, unit: "km per calendar weekday", horizontal: true, identifierPrefix: "weekdayDistance")
                Text("Known recorded kilometres divided by the number of each weekday in the selected calendar window, including days with no archived journeys. Missing collection days can lower this average.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            NativeCard(title: "Standing still by departure hour", symbol: "pause.circle", tint: NativeTheme.violet) {
                Text("Departure hour · India time").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                LabBarChart(values: idleHours, unit: "% of engine time", compactCategories: true, identifierPrefix: "idleHour")
                Text("Time-weighted: idle minutes ÷ (moving + idle minutes), for trips with both values. Hourly differences mix routes, trip lengths and traffic; they do not establish a better departure time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            hotspotsCard
            commuteCard
            NativeCard(title: "Journey lengths", symbol: "point.topleft.down.curvedto.point.bottomright.up") {
                LabBarChart(values: lengthHistogram, unit: "trips")
                Text("Provider-reported distance, before the fuel model’s calibration. Whole-kilometre reporting is especially coarse for short trips.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            NativeCard(title: "Reported maximum speeds", symbol: "gauge.with.dots.needle.67percent") {
                Text("Speed bands · km/h").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                LabBarChart(values: speedHistogram, unit: "trips")
                Text("Maximum speed reported for each trip. This distribution is descriptive; higher speed is not a performance target or a measure of driving quality.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            NativeCard(title: "Provider event exposure", symbol: "exclamationmark.triangle", tint: NativeTheme.coral) {
                Picker("Compare event exposure by", selection: $eventGrouping) {
                    ForEach(NativeEventGrouping.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("eventExposureGrouping")
                LabBarChart(values: eventRates, unit: "events per 1,000 recorded km", horizontal: true, identifierPrefix: "eventExposure")
                Text("Comparable evidence: \(eventExposure.tripCount) trips · \(NativeFormat.number(eventExposure.distanceKM, digits: 1)) recorded km. All event types use the same complete trip cohort.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Provider-defined harsh-braking, acceleration and overspeed counts, normalized by known distance. A small denominator can produce a large rate. Road, traffic and provider definitions matter.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: revision) {
            let all = snapshot.trips
            let latest = anchor
            let selectedWindow = window
            let prepared = await Task.detached(priority: .userInitiated) {
                let filtered = all.filter { selectedWindow.contains($0.start, anchor: latest) }
                return (filtered, PatternEventExposure(trips: filtered))
            }.value
            guard !Task.isCancelled else { return }
            trips = prepared.0
            eventExposure = prepared.1
            chosenJourney = ""
        }
    }

    private var hotspotsCard: some View {
        NativeCard(title: "Historical slow areas", symbol: "mappin.and.ellipse") {
            let hotspots = Array((snapshot.overview.hotspots ?? []).prefix(12))
            if hotspots.isEmpty { Text("No usable historical GPS slow areas are available.").foregroundStyle(.secondary) }
            ForEach(Array(hotspots.enumerated()), id: \.offset) { index, hotspot in
                NavigationLink {
                    NativeAtlasView(snapshot: snapshot, focusHotspot: hotspot)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Slow area \(index + 1)").font(.subheadline.weight(.semibold))
                        Text("\(NativeFormat.number(hotspot.minutes, digits: 1)) archived slow minutes · \(hotspot.trips.map(String.init) ?? "unknown") trips · \(NativeFormat.number(hotspot.minutesPerTrip, digits: 1)) min/trip")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Full saved GPS window. Sparse historical samples identify repeated slow movement, not live congestion, a cause of delay or a recommended route. Open an area to inspect it in Atlas.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var rhythm: [LabHeatCell] {
        var counts = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        for trip in trips {
            guard let date = trip.start else { continue }
            counts[LabMath.weekday(date)][Int(LabMath.hour(date))] += 1
        }
        return (0..<7).flatMap { day in (0..<24).map { hour in
            LabHeatCell(column: hour, row: day, value: Double(counts[day][hour]))
        } }
    }

    private var weekdayDistance: [LabCategory] {
        let calendar = AnalyticsDate.calendar
        guard let latest = anchor, let earliest = snapshot.history.firstDate else { return [] }
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: latest))!
        let cutoff = window.days.flatMap { calendar.date(byAdding: .day, value: -$0, to: end) } ?? calendar.startOfDay(for: earliest)
        let start = max(cutoff, calendar.startOfDay(for: earliest))
        let days = max(1, calendar.dateComponents([.day], from: start, to: end).day ?? 1)
        let first = LabMath.weekday(start)
        return (0..<7).compactMap { weekday in
            let occurrences = days / 7 + ((0..<(days % 7)).contains { (first + $0) % 7 == weekday } ? 1 : 0)
            guard occurrences > 0 else { return nil }
            let selected = trips.filter { $0.start.map(LabMath.weekday) == weekday }
            let distances = selected.compactMap { LabMath.valid($0.distanceKM) }
            return LabCategory(label: Self.weekdayNames[weekday], value: distances.reduce(0, +) / Double(occurrences),
                               detail: "\(selected.count) trips · \(occurrences) calendar weekdays · \(distances.count) distances recorded",
                               isMissing: !selected.isEmpty && distances.isEmpty)
        }
    }

    private var idleHours: [LabCategory] {
        (0..<24).map { hour in
            let group = trips.filter { $0.start.map { Int(LabMath.hour($0)) } == hour }
            let valid = group.compactMap { trip -> (Double, Double)? in
                guard let idle = LabMath.valid(trip.idleMinutes), let engine = LabMath.valid(trip.engineMinutes), engine > 0 else { return nil }
                return (idle, engine)
            }
            let engine = valid.map(\.1).reduce(0, +)
            return LabCategory(label: LabMath.hourLabel(Double(hour)), value: engine > 0 ? valid.map(\.0).reduce(0, +) / engine * 100 : 0,
                               detail: engine > 0 ? "\(valid.count) trips · \(NativeFormat.duration(engine)) engine time" : "No usable engine-time observations for this departure hour",
                               isMissing: engine <= 0)
        }
    }

    private var journeyPairs: [(key: String, trips: [NativeTrip])] {
        let eligible = trips.filter { !($0.origin ?? "").isEmpty && !($0.destination ?? "").isEmpty }
        return Dictionary(grouping: eligible) { "\($0.origin!) → \($0.destination!)" }
            .map { (key: $0.key, trips: $0.value) }
            .sorted { $0.trips.count == $1.trips.count ? $0.key < $1.key : $0.trips.count > $1.trips.count }
    }
    private var activeJourney: String { chosenJourney.isEmpty ? journeyPairs.first?.key ?? "" : chosenJourney }
    private var commuteTrips: [NativeTrip] { journeyPairs.first { $0.key == activeJourney }?.trips ?? [] }
    private var commutePoints: [LabPoint] {
        commuteTrips.compactMap { trip in
            guard let start = trip.start, let duration = LabMath.valid(trip.elapsedMinutes) else { return nil }
            return LabPoint(id: trip.id, x: LabMath.hour(start), y: duration,
                            series: "Archived journeys", detail: "\(NativeFormat.date(start, includeTime: true)) · \(NativeFormat.number(trip.distanceKM, digits: 1)) km",
                            tripID: trip.id)
        }
    }
    private var commuteCard: some View {
        NativeCard(title: "Recurring journey timing", symbol: "arrow.left.arrow.right") {
            if journeyPairs.isEmpty {
                Text("Inferred origin and destination labels are needed before recurring journeys can be grouped.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Picker("Journey and direction", selection: Binding(get: { activeJourney }, set: { chosenJourney = $0 })) {
                    ForEach(journeyPairs.prefix(20), id: \.key) { pair in Text("\(pair.key) · \(pair.trips.count)").tag(pair.key) }
                }.pickerStyle(.menu)
                LabXYChart(points: commutePoints, xTitle: "Departure hour · IST", yTitle: "minutes", snapshot: snapshot)
                let durations = commutePoints.map(\.y)
                LabeledContent("Typical / 95th percentile", value: "\(NativeFormat.duration(LabMath.quantile(durations, 0.5))) / \(NativeFormat.duration(LabMath.quantile(durations, 0.95)))")
                    .font(.subheadline)
                Text("Inferred places and observed timing only. Trip duration and traffic vary; this is not a controlled route comparison. Open a selected journey for the stricter earlier-trip baseline.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var lengthHistogram: [LabCategory] {
        histogram(trips.compactMap { LabMath.valid($0.distanceKM) }, edges: [0, 2, 5, 10, 25, 50, .infinity], labels: ["<2", "2–5", "5–10", "10–25", "25–50", "50+ km"])
    }
    private var speedHistogram: [LabCategory] {
        histogram(trips.compactMap { LabMath.valid($0.maxSpeedKMH) }, edges: [0, 20, 40, 60, 80, 100, .infinity], labels: ["<20", "20–40", "40–60", "60–80", "80–100", "100+"])
    }
    private func histogram(_ values: [Double], edges: [Double], labels: [String]) -> [LabCategory] {
        guard !values.isEmpty else { return [] }
        return labels.indices.map { index in
            LabCategory(label: labels[index], value: Double(values.filter { $0 >= edges[index] && $0 < edges[index + 1] }.count))
        }
    }
    private var eventRates: [LabCategory] {
        let values = eventGrouping == .type ? eventExposure.byType : eventExposure.byWeekday
        return values.map { row in
            LabCategory(label: row.label, value: row.rate ?? 0,
                        detail: "\(NativeFormat.number(row.count)) events · \(row.tripCount) comparable trips · \(NativeFormat.number(row.distanceKM, digits: 1)) recorded km",
                        isMissing: row.rate == nil)
        }
    }
}
