import Foundation

/// The read-only Bluelink calls the collector needs. Paths are relative to `/api/v1/spa/`.
public protocol BluelinkAPI: Sendable {
    func vehicles() async throws -> (raw: Data, list: [Vehicle])
    func get(_ path: String) async throws -> Data
    func post(_ path: String, json: [String: Any]) async throws -> Data
}

/// India's `_get_authenticated_headers` ignores the vehicle (no `Ccuccs2protocolsupport`, no `Stamp`),
/// so collect.py sends no per-vehicle header; neither do we.
extension BluelinkClient: BluelinkAPI {
    public func get(_ path: String) async throws -> Data {
        try await get(path, extraHeaders: [:])
    }

    public func post(_ path: String, json: [String: Any]) async throws -> Data {
        try await post(path, json: json, extraHeaders: [:])
    }
}

public struct CollectStats: Codable, Equatable, Sendable {
    public var daysFetched = 0
    public var daysSkipped = 0
    public var tripsFetched = 0
    public var tripsSkipped = 0
    public var errors: [String] = []
    /// First day synced (earliest over all vehicles) and today, as `yyyyMMdd` IST day keys.
    public var from = ""
    public var to = ""
}

/// Swift port of `collect.py`: archives Bluelink responses verbatim into the book.
///
/// Archive rules: a day file is final once it was fetched at least `recentDays` after that day (fetch time
/// from the `<day>.meta.json` sidecar, else the file's modification date); final files are never re-fetched
/// or overwritten. Each run resumes from the earliest missing or non-final day. Trips are refetched only for
/// non-final days whose saved route has at most one point. A response is written only when `retCode == "S"`.
/// A day on or before today - recentDays whose file or sidecar is an iCloud placeholder that can't be
/// downloaded counts as present and final; a recent-window placeholder day is fetched as non-final. A trip
/// placeholder that can't be downloaded is left alone. Every such skip is recorded in `errors`.
/// All day keys use the Asia/Kolkata calendar.
public struct Collector: Sendable {
    public static let recentDays = 7

    let book: Book
    let api: BluelinkAPI
    let now: @Sendable () -> Date
    let pause: Duration
    /// How long to wait for one iCloud placeholder to download. After the first failure in a run, further
    /// placeholders are treated as not downloadable without waiting.
    public var downloadTimeout: TimeInterval = 5

    public init(book: Book, api: BluelinkAPI, now: @escaping @Sendable () -> Date = Date.init,
                pause: Duration = .milliseconds(600)) {
        self.book = book
        self.api = api
        self.now = now
        self.pause = pause
    }

    // MARK: IST calendar

    static let ist = TimeZone(identifier: "Asia/Kolkata")!

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = ist
        return c
    }

    static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = ist
        f.dateFormat = format
        return f
    }

    static func dayKey(_ date: Date) -> String { formatter("yyyyMMdd").string(from: date) }

    /// Midnight IST of a `yyyyMMdd` key (nil if malformed).
    static func dayStart(_ key: String) -> Date? {
        guard key.count == 8, key.allSatisfy(\.isASCII), key.allSatisfy(\.isNumber) else { return nil }
        return formatter("yyyyMMdd").date(from: key)
    }

    static func addDays(_ key: String, _ n: Int) -> String {
        dayKey(calendar.date(byAdding: .day, value: n, to: dayStart(key)!)!)
    }

    /// True if a day file fetched at `fetchedAt` was fetched at least `recentDays` (IST calendar days) after `day`.
    public static func isFinal(fetchedAt: Date?, day: String) -> Bool {
        guard let fetchedAt, let start = dayStart(day) else { return false }
        let fetchedDay = calendar.startOfDay(for: fetchedAt)
        let diff = calendar.dateComponents([.day], from: start, to: fetchedDay).day ?? 0
        return diff >= recentDays
    }

    // MARK: paths

    static func dayRel(_ vid: String, _ key: String) -> String { "raw/days/\(vid)/\(key).json" }
    static func metaRel(_ vid: String, _ key: String) -> String { "raw/days/\(vid)/\(key).meta.json" }
    static func tripRel(_ vid: String, _ tid: String) -> String { "raw/trips/\(vid)/\(tid).json" }

    private func onDisk(_ rel: String) -> Bool {
        FileManager.default.fileExists(atPath: book.url(rel).path)
    }

    /// Present only as an iCloud placeholder.
    private func isPlaceholder(_ rel: String) -> Bool { book.exists(rel) && !onDisk(rel) }

    // MARK: day state

    enum DayStatus: Equatable {
        /// No day file (not even a placeholder): fetch.
        case missing
        /// Saved but not final (or a recent-window placeholder): fetch and overwrite.
        case recent
        /// Saved and final: never fetch or overwrite.
        case final
        /// An old day (on or before today - recentDays) whose file or sidecar is an iCloud placeholder that
        /// isn't on disk: treated as present and final (R3), left untouched.
        case unverified
    }

    /// The status of a saved day from what is on disk now. Placeholders mean "final" only for days on or
    /// before `floor` (today - recentDays); a later day can never be final (that needs fetched_at >= day + 7
    /// > now), so a recent-window placeholder is fetched like any non-final day (as collect.py would).
    func dayStatus(vid: String, key: String, floor: String) -> DayStatus {
        let day = Self.dayRel(vid, key), meta = Self.metaRel(vid, key)
        guard book.exists(day) else { return .missing }
        if isPlaceholder(day) || isPlaceholder(meta) { return key <= floor ? .unverified : .recent }
        return Self.isFinal(fetchedAt: fetchedAt(vid: vid, key: key), day: key) ? .final : .recent
    }

    /// Sidecar `fetched_at`, else the day file's modification date.
    func fetchedAt(vid: String, key: String) -> Date? {
        let meta = Self.metaRel(vid, key)
        if onDisk(meta), let data = try? book.read(meta),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let s = obj["fetched_at"] as? String,
           let d = ISO8601DateFormatter().date(from: s) {
            return d
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: book.url(Self.dayRel(vid, key)).path)
        return attrs?[.modificationDate] as? Date
    }

    /// Saved day keys (day files only; sidecars and other names ignored), sorted.
    func savedDays(vid: String) throws -> [String] {
        try book.list("raw/days/\(vid)").compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            let key = String(name.dropLast(5))
            return Self.dayStart(key) == nil ? nil : key
        }.sorted()
    }

    /// Where a sync starts (collect.py `resume_from`): with no saved day, `today - recentDays`; otherwise the
    /// earliest saved day, advanced day by day while it is before `today - recentDays` and final. The result
    /// is therefore the first missing or non-final day before the floor, or the floor itself if all of those
    /// are final, or the earliest saved day when that is already after the floor (as in Python, the days
    /// between the floor and a later first file are then not synced). Synchronous, so old placeholders are
    /// treated as final without trying to download them.
    public func resumeFrom(vid: String, today: String) throws -> String {
        let floor = Self.addDays(today, -Self.recentDays)
        guard var day = try savedDays(vid: vid).first else { return floor }
        while day < floor, [.final, .unverified].contains(dayStatus(vid: vid, key: day, floor: floor)) {
            day = Self.addDays(day, 1)
        }
        return day
    }

    // MARK: run

    private final class RunState: @unchecked Sendable {
        var stats = CollectStats()
        var downloadsFailed = false
    }

    /// Tries to bring a placeholder down (bounded by `downloadTimeout`); returns true if the file is on disk.
    /// After the first failure in a run, later placeholders are not waited for.
    private func download(_ rel: String, _ state: RunState) async throws -> Bool {
        if onDisk(rel) { return true }
        if !book.exists(rel) || state.downloadsFailed { return false }
        do {
            try await book.ensureDownloaded(rel, timeout: downloadTimeout)
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            state.downloadsFailed = true
            return false
        }
    }

    /// Asks iCloud to start downloading a placeholder without waiting (a zero-timeout `ensureDownloaded`
    /// issues the request and returns), so many files can come down in parallel.
    private func startDownload(_ rel: String) async {
        guard isPlaceholder(rel) else { return }
        try? await book.ensureDownloaded(rel, timeout: 0)
    }

    /// `dayStatus`, after trying to download placeholders of the day file and sidecar.
    private func dayStatus(vid: String, key: String, floor: String, _ state: RunState) async throws -> DayStatus {
        if book.exists(Self.dayRel(vid, key)) {
            _ = try await download(Self.metaRel(vid, key), state)
            _ = try await download(Self.dayRel(vid, key), state)
        }
        return dayStatus(vid: vid, key: key, floor: floor)
    }

    private func resumeFrom(vid: String, today: String, _ state: RunState) async throws -> String {
        let floor = Self.addDays(today, -Self.recentDays)
        let saved = try savedDays(vid: vid)
        guard var day = saved.first else { return floor }
        // Fresh phone: everything may be placeholders. Start all downloads in the walk range up front so the
        // serial walk below doesn't wait for each file in turn.
        for key in saved where key < floor {
            await startDownload(Self.metaRel(vid, key))
            await startDownload(Self.dayRel(vid, key))
        }
        var unverified = 0
        while day < floor {
            let status = try await dayStatus(vid: vid, key: day, floor: floor, state)
            guard status == .final || status == .unverified else { break }
            if status == .unverified { unverified += 1 }
            day = Self.addDays(day, 1)
        }
        if unverified > 0 {
            state.stats.errors.append(
                "\(unverified) days before \(day): iCloud placeholder not downloaded, left untouched")
        }
        return day
    }

    /// Snapshot (optional) plus every day from the resume point to today, for each vehicle. Transport
    /// errors, cancellation and book errors abort the run (files already written stay); failed responses
    /// are recorded in `errors`. Writes `state/last_sync.json` when the run completes.
    public func run(snapshot: Bool = true) async throws -> CollectStats {
        let state = RunState()
        let today = Self.dayKey(now())
        state.stats.to = today
        let vehicles = try await api.vehicles().list
        for v in vehicles {
            if snapshot { try await self.snapshot(v, state) }
            let from = try await resumeFrom(vid: v.id, today: today, state)
            if state.stats.from.isEmpty || from < state.stats.from { state.stats.from = from }
            let floor = Self.addDays(today, -Self.recentDays)
            var day = from
            while day <= today {
                try await self.day(vid: v.id, key: day, floor: floor, state)
                day = Self.addDays(day, 1)
            }
        }
        try book.writeAtomic("state/last_sync.json",
                             Data("{\"last_sync\": \"\(istTimestamp(now()))\"}".utf8))
        return state.stats
    }

    // MARK: calls

    private func fetchGet(_ path: String) async throws -> Data {
        try await Task.sleep(for: pause)
        return try await api.get(path)
    }

    private func fetchPost(_ path: String, _ body: [String: Any]) async throws -> Data {
        try await Task.sleep(for: pause)
        return try await api.post(path, json: body)
    }

    static func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func isOK(_ obj: [String: Any]?) -> Bool { (obj?["retCode"] as? String) == "S" }

    static func brief(_ data: Data) -> String { String(String(decoding: data, as: UTF8.self).prefix(150)) }

    private func snapshot(_ v: Vehicle, _ state: RunState) async throws {
        let base = "vehicles/\(v.id)"
        let status = v.ccs2 == 0 ? "/status/latest" : "/ccs2/carstatus/latest"
        let ts = Self.formatter("yyyyMMdd'T'HHmmss").string(from: now())
        for (name, path) in [("vehicles", "vehicles"), ("status_latest", base + status),
                             ("location_park", base + "/location/park"),
                             ("maintenance_alert", base + "/setting/alert/maintenance")] {
            let data = try await fetchGet(path)
            if Self.isOK(Self.object(data)) {
                try book.writeAtomic("raw/snapshots/\(v.id)/\(ts)/\(name).json", data)
            } else {
                state.stats.errors.append("\(name): \(Self.brief(data))")
            }
        }
    }

    private func day(vid: String, key: String, floor: String, _ state: RunState) async throws {
        let rel = Self.dayRel(vid, key)
        let status = try await dayStatus(vid: vid, key: key, floor: floor, state)
        let recent = status == .missing || status == .recent
        var trips: [[String: Any]]
        if !recent {
            state.stats.daysSkipped += 1
            if status == .unverified {
                state.stats.errors.append("day \(key): iCloud placeholder not downloaded, left untouched")
                guard onDisk(rel) else { return }  // only the sidecar was a placeholder: still check trips
            }
            // A final day still lists its trips so missing trip files get fetched (as collect.py does).
            guard let data = try? book.read(rel), let obj = Self.object(data) else {
                state.stats.errors.append("day \(key): saved file unreadable, trips not checked")
                return
            }
            trips = Self.tripsIn(obj)
        } else {
            let data = try await fetchPost("vehicles/\(vid)/tripinfo", ["tripPeriodType": 1, "setTripDay": key])
            let obj = Self.object(data)
            guard Self.isOK(obj), let obj else {
                state.stats.errors.append("day \(key): \(Self.brief(data))")
                return
            }
            try book.writeAtomic(rel, data)
            try book.writeAtomic(Self.metaRel(vid, key),
                                 Data("{\n  \"fetched_at\": \"\(istTimestamp(now()))\"\n}".utf8))
            state.stats.daysFetched += 1
            trips = Self.tripsIn(obj)
        }
        for trip in trips { try await self.trip(vid: vid, key: key, trip: trip, recent: recent, state) }
    }

    static func tripsIn(_ resp: [String: Any]) -> [[String: Any]] {
        let days = (resp["resMsg"] as? [String: Any])?["dayTripList"] as? [[String: Any]] ?? []
        return days.flatMap { $0["tripList"] as? [[String: Any]] ?? [] }
    }

    func pointCount(_ rel: String) -> Int {
        guard onDisk(rel), let data = try? book.read(rel), let obj = Self.object(data),
              let info = (obj["resMsg"] as? [String: Any])?["tripInfo"] as? [String: Any] else { return 0 }
        return (info["tripList"] as? [Any])?.count ?? 0
    }

    private func trip(vid: String, key: String, trip: [String: Any], recent: Bool, _ state: RunState) async throws {
        // Bluelink sends serviceTID as a JSON number (tripStartTime/tripEndTime as strings today); the file name
        // uses its decimal form (as collect.py's f-string did) and the POST passes the values through unchanged.
        guard let rawTID = trip["serviceTID"], let tid = Self.tidString(rawTID),
              !tid.isEmpty, !tid.contains("/"), !tid.hasPrefix("."),
              let start = trip["tripStartTime"], let end = trip["tripEndTime"] else {
            state.stats.errors.append("trip in day \(key): bad trip entry")
            return
        }
        let rel = Self.tripRel(vid, tid)
        if book.exists(rel) {
            // Refetch only recent trips whose route hasn't arrived yet; never touch older files.
            // A placeholder that can't be downloaded is left alone.
            if recent, !(try await download(rel, state)) {
                state.stats.tripsSkipped += 1
                state.stats.errors.append("trip \(tid): iCloud placeholder not downloaded, left untouched")
                return
            }
            if !recent || pointCount(rel) > 1 {
                state.stats.tripsSkipped += 1
                return
            }
        }
        let data = try await fetchPost("vehicles/\(vid)/tripinfo/detail", [
            "tripPeriodType": 1,
            "setTripDay": key,
            "setTripStartTime": start,
            "setServiceTID": rawTID,
            "tripStartTime": start,
            "tripEndTime": end,
        ])
        let obj = Self.object(data)
        if Self.isOK(obj), Self.truthy((obj?["resMsg"] as? [String: Any])?["tripInfo"]) {
            try book.writeAtomic(rel, data)
            state.stats.tripsFetched += 1
        } else {
            state.stats.errors.append("trip \(tid): \(Self.brief(data))")
        }
    }

    /// Decimal string of a trip id given as a JSON string or number (integer, or a float with no fraction);
    /// nil for booleans, fractional or non-finite numbers and other types.
    static func tidString(_ v: Any) -> String? {
        if let s = v as? String { return s }
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        if CFNumberIsFloatType(n) {
            let d = n.doubleValue
            guard d.isFinite, d == d.rounded(), abs(d) < 9.0e15 else { return nil }
            return String(Int64(d))
        }
        return n.stringValue
    }

    /// Python truthiness for a JSON value.
    static func truthy(_ v: Any?) -> Bool {
        switch v {
        case nil, is NSNull: return false
        case let d as [String: Any]: return !d.isEmpty
        case let a as [Any]: return !a.isEmpty
        case let s as String: return !s.isEmpty
        case let n as NSNumber: return n != 0
        default: return true
        }
    }
}
