import Foundation
import MapKit

/// Rendering-only projections. Original records are never changed or resampled into fake observations.
struct NativeReplaySample: Identifiable, Sendable {
    let id: Int
    let segment: Int
    let latitude: Double
    let longitude: Double
    let seconds: Double
    let speedKMH: Double?
    let accelerationMS2: Double?
}

struct NativeTripReplayData: Sendable {
    let samples: [NativeReplaySample]
    let segments: [[RouteCoordinate]]
    var duration: Double { samples.last?.seconds ?? 0 }
    var canPlay: Bool { samples.count > 1 && duration > (samples.first?.seconds ?? 0) }
    static let empty = NativeTripReplayData(samples: [], segments: [])

    init(trip: NativeTrip) {
        let segments = trip.record.route == true ? trip.routeSegments : []
        self.segments = segments
        var samples: [NativeReplaySample] = []
        var lastTime = -Double.infinity
        for (segmentIndex, points) in segments.enumerated() {
            var previous: NativeReplaySample?
            for point in points {
                guard let seconds = point.elapsedSeconds, seconds.isFinite, seconds >= 0, seconds > lastTime else {
                    previous = nil
                    continue
                }
                let speed = point.estimatedSpeedKMH.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                var acceleration: Double?
                if let before = previous, let v0 = before.speedKMH, let v1 = speed {
                    let gap = seconds - before.seconds
                    if gap >= 1 && gap <= 120 { acceleration = (v1 - v0) / 3.6 / gap }
                }
                let sample = NativeReplaySample(id: point.id, segment: segmentIndex,
                                                latitude: point.latitude, longitude: point.longitude,
                                                seconds: seconds, speedKMH: speed,
                                                accelerationMS2: acceleration)
                samples.append(sample)
                previous = sample
                lastTime = seconds
            }
        }
        self.samples = samples
    }

    private init(samples: [NativeReplaySample], segments: [[RouteCoordinate]]) {
        self.samples = samples
        self.segments = segments
    }

    /// Show an actual earlier sample; never interpolate a vehicle location through an unobserved gap.
    func sample(at seconds: Double) -> NativeReplaySample? {
        guard !samples.isEmpty, seconds.isFinite else { return nil }
        var low = 0, high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].seconds <= seconds { low = mid + 1 } else { high = mid }
        }
        return samples[max(0, low - 1)]
    }
}

struct NativeAtlasLine: Identifiable, Sendable {
    let id: String
    let tripIndex: Int
    let coordinates: [RouteCoordinate]
    let speedBand: Int?
    let departureBand: Int
    private let geometry: NativeAtlasGeometry

    /// Reuses the same MapKit geometry on every render; callers must not mutate its metadata.
    var polyline: MKPolyline { geometry.polyline }

    init(id: String, tripIndex: Int, coordinates: [RouteCoordinate], speedBand: Int?, departureBand: Int) {
        self.id = id
        self.tripIndex = tripIndex
        self.coordinates = coordinates
        self.speedBand = speedBand
        self.departureBand = departureBand
        geometry = NativeAtlasGeometry(coordinates: coordinates)
    }
}

/// MapKit does not declare MKPolyline Sendable. Its geometry is copied at construction and has
/// no mutation API. We construct it before publication and never mutate title/subtitle afterward;
/// the unchecked boundary is limited to this immutable, privately retained geometry cache.
private struct NativeAtlasGeometry: @unchecked Sendable {
    let polyline: MKPolyline

    init(coordinates: [RouteCoordinate]) {
        let points = coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        polyline = MKPolyline(coordinates: points, count: points.count)
    }
}

struct NativeAtlasCell: Identifiable, Sendable {
    let id: String
    let latitude: Double
    let longitude: Double
    let tripIndices: [Int]

    func visits(through visibleCount: Int) -> Int {
        var low = 0, high = tripIndices.count
        while low < high {
            let mid = (low + high) / 2
            if tripIndices[mid] < visibleCount { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

struct NativeAtlasRenderData: Sendable {
    static let lineBudget = 450
    static let speedLineBudget = 600
    static let densityBudget = 600
    let trips: [NativeTrip]
    let lines: [NativeAtlasLine]
    let speedLines: [NativeAtlasLine]
    let density: [NativeAtlasCell]
    let routedTripCount: Int
    let pointCount: Int
    let sourceLineCount: Int
    let sourceSpeedLineCount: Int
    let densityCellSizeDegrees: Double
    let latitudeBounds: ClosedRange<Double>?
    let longitudeBounds: ClosedRange<Double>?
    static let empty = NativeAtlasRenderData(trips: [], lines: [], speedLines: [], density: [], routedTripCount: 0,
                                             pointCount: 0, sourceLineCount: 0, sourceSpeedLineCount: 0,
                                             densityCellSizeDegrees: 0.002, latitudeBounds: nil, longitudeBounds: nil)

    static func build(trips source: [NativeTrip]) -> NativeAtlasRenderData {
        let trips = source.sorted {
            if $0.start == $1.start { return $0.id < $1.id }
            return ($0.start ?? .distantPast) < ($1.start ?? .distantPast)
        }
        var minLat = Double.infinity, maxLat = -Double.infinity
        var minLon = Double.infinity, maxLon = -Double.infinity
        var routed = 0, pointCount = 0
        for trip in trips where trip.hasRoute {
            if Task.isCancelled { return .empty }
            routed += 1
            for point in trip.coordinates {
                pointCount += 1
                if pointCount % 512 == 0 && Task.isCancelled { return .empty }
                minLat = min(minLat, point.latitude); maxLat = max(maxLat, point.latitude)
                minLon = min(minLon, point.longitude); maxLon = max(maxLon, point.longitude)
            }
        }
        // At most 23 × 23 occupied cells, even for a very long, narrow geographic extent.
        // Range changes rebuild this projection, so a narrower history automatically gains detail.
        let grid = minLat.isFinite ? max(0.002, max((maxLat - minLat) / 22, (maxLon - minLon) / 22)) : 0.002
        var lines = OverlayBudget(limit: lineBudget), speedLines = OverlayBudget(limit: speedLineBudget)
        struct Cell { var latitude = 0.0; var longitude = 0.0; var visits: [Int] = [] }
        var cells: [String: Cell] = [:]
        for (tripIndex, trip) in trips.enumerated() {
            if Task.isCancelled { return .empty }
            guard trip.hasRoute else { continue }
            let hour = trip.start.map { AnalyticsDate.calendar.component(.hour, from: $0) } ?? 0
            let timeBand = hour < 6 ? 0 : hour < 12 ? 1 : hour < 18 ? 2 : 3
            var visited = Set<String>()
            for (segmentIndex, points) in trip.routeSegments.enumerated() where points.count >= 2 {
                let prefix = "\(trip.id)-\(segmentIndex)"
                let displayed = simplify(points, limit: 160)
                lines.append(AtlasLineCandidate(id: prefix, tripIndex: tripIndex, coordinates: displayed,
                                             speedBand: nil, departureBand: timeBand))
                var run: [RouteCoordinate] = [], previousBand: Int?, runIndex = 0
                for point in displayed {
                    let band = speedBand(point.estimatedSpeedKMH)
                    if !run.isEmpty, band != previousBand {
                        run.append(point)
                        if run.count >= 2 {
                            speedLines.append(AtlasLineCandidate(id: "\(prefix)-s\(runIndex)", tripIndex: tripIndex,
                                                              coordinates: run, speedBand: previousBand,
                                                              departureBand: timeBand))
                            runIndex += 1
                        }
                        run = [point]
                    } else { run.append(point) }
                    previousBand = band
                }
                if run.count >= 2 {
                    speedLines.append(AtlasLineCandidate(id: "\(prefix)-s\(runIndex)", tripIndex: tripIndex,
                                                      coordinates: run, speedBand: previousBand,
                                                      departureBand: timeBand))
                }
                for (pointIndex, point) in points.enumerated() {
                    if pointIndex % 512 == 0 && Task.isCancelled { return .empty }
                    let key = "\(Int(floor(point.latitude / grid))):\(Int(floor(point.longitude / grid)))"
                    guard visited.insert(key).inserted else { continue }
                    var cell = cells[key] ?? Cell()
                    cell.latitude += point.latitude; cell.longitude += point.longitude
                    cell.visits.append(tripIndex)
                    cells[key] = cell
                }
            }
        }
        let density = cells.keys.sorted().compactMap { key -> NativeAtlasCell? in
            guard let cell = cells[key], !cell.visits.isEmpty else { return nil }
            let count = Double(cell.visits.count)
            return NativeAtlasCell(id: key, latitude: cell.latitude / count, longitude: cell.longitude / count,
                                   tripIndices: cell.visits)
        }
        return NativeAtlasRenderData(trips: trips,
                                      lines: lines.values.sorted { ($0.tripIndex, $0.id) < ($1.tripIndex, $1.id) }.map(\.renderLine),
                                      speedLines: speedLines.values.sorted { ($0.tripIndex, $0.id) < ($1.tripIndex, $1.id) }.map(\.renderLine),
                                      density: density, routedTripCount: routed, pointCount: pointCount,
                                      sourceLineCount: lines.seen, sourceSpeedLineCount: speedLines.seen,
                                      densityCellSizeDegrees: grid,
                                      latitudeBounds: minLat.isFinite ? minLat...maxLat : nil,
                                      longitudeBounds: minLon.isFinite ? minLon...maxLon : nil)
    }

    static func speedBand(_ speed: Double?) -> Int? {
        guard let speed, speed.isFinite, speed >= 0 else { return nil }
        return speed < 20 ? 0 : speed < 40 ? 1 : speed < 60 ? 2 : 3
    }

    /// Deterministic reservoir: global overlay and vertex costs stay bounded without favouring recent trips.
    /// Candidates defer MapKit allocation until after the global budgets select retained geometry.
    private struct AtlasLineCandidate {
        let id: String
        let tripIndex: Int
        let coordinates: [RouteCoordinate]
        let speedBand: Int?
        let departureBand: Int

        var renderLine: NativeAtlasLine {
            NativeAtlasLine(id: id, tripIndex: tripIndex, coordinates: coordinates,
                            speedBand: speedBand, departureBand: departureBand)
        }
    }

    private struct OverlayBudget {
        let limit: Int
        var values: [AtlasLineCandidate] = []
        var seen = 0
        private var random: UInt64 = 7
        init(limit: Int) { self.limit = limit }
        mutating func append(_ line: AtlasLineCandidate) {
            seen += 1
            if values.count < limit { values.append(line); return }
            random = random &* 6_364_136_223_846_793_005 &+ 1
            let candidate = Int(random % UInt64(seen))
            if candidate < limit { values[candidate] = line }
        }
    }

    private static func simplify(_ points: [RouteCoordinate], limit: Int) -> [RouteCoordinate] {
        guard points.count > limit, limit >= 2 else { return points }
        return (0..<limit).map { points[Int(Double($0) * Double(points.count - 1) / Double(limit - 1))] }
    }
}
