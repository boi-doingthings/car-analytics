import Foundation

public enum EntryKind: String, CaseIterable, Sendable {
    case refuel, service, maintenance

    /// Folder under the book root, e.g. `log/refuels`.
    public var dir: String {
        switch self {
        case .refuel: "log/refuels"
        case .service: "log/services"
        case .maintenance: "log/maintenance"
        }
    }
}

public enum EntryError: Error, Equatable {
    case invalidID(String)
}

/// A log entry stored as `<dir>/<id>.json` (schema in docs/entry-schemas.md).
public protocol Entry: Codable, Identifiable, Sendable where ID == String {
    static var kind: EntryKind { get }
    var schema: Int { get }
    var id: String { get }
}

public let currentSchema = 1

/// A fresh lowercase UUID v4 string.
public func newEntryID() -> String { UUID().uuidString.lowercased() }

/// `entered_at` format: ISO 8601, IST offset, whole seconds.
public func istTimestamp(_ date: Date = Date()) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 19800)
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
    return f.string(from: date)
}

private struct SchemaProbe: Decodable { let schema: Int? }

// MARK: Refuel

public struct Refuel: Entry, Equatable {
    public static let kind = EntryKind.refuel
    public var schema: Int
    public var id: String
    public var enteredAt: String
    public var date: String
    public var time: String?
    public var litres: Double?
    public var amount: Double?
    public var rate: Double?
    public var odometerKm: Double?
    public var fullTank: Bool?
    public var missed: Bool
    public var station: String
    public var company: String?
    public var lat: Double?
    public var lon: Double?
    public var note: String?

    public init(schema: Int = currentSchema, id: String = newEntryID(), enteredAt: String = istTimestamp(),
                date: String, time: String? = nil, litres: Double? = nil, amount: Double? = nil,
                rate: Double? = nil, odometerKm: Double? = nil, fullTank: Bool? = nil, missed: Bool = false,
                station: String, company: String? = nil, lat: Double? = nil, lon: Double? = nil,
                note: String? = nil) {
        self.schema = schema; self.id = id; self.enteredAt = enteredAt; self.date = date; self.time = time
        self.litres = litres; self.amount = amount; self.rate = rate; self.odometerKm = odometerKm
        self.fullTank = fullTank; self.missed = missed; self.station = station; self.company = company
        self.lat = lat; self.lon = lon; self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case schema, id, date, time, litres, amount, rate, missed, station, company, lat, lon, note
        case enteredAt = "entered_at", odometerKm = "odometer_km", fullTank = "full_tank"
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        id = try c.decode(String.self, forKey: .id)
        enteredAt = try c.decode(String.self, forKey: .enteredAt)
        date = try c.decode(String.self, forKey: .date)
        time = try c.decodeIfPresent(String.self, forKey: .time)
        litres = try c.decodeIfPresent(Double.self, forKey: .litres)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount)
        rate = try c.decodeIfPresent(Double.self, forKey: .rate)
        odometerKm = try c.decodeIfPresent(Double.self, forKey: .odometerKm)
        fullTank = try c.decodeIfPresent(Bool.self, forKey: .fullTank)
        missed = try c.decodeIfPresent(Bool.self, forKey: .missed) ?? false
        station = try c.decode(String.self, forKey: .station)
        company = try c.decodeIfPresent(String.self, forKey: .company)
        lat = try c.decodeIfPresent(Double.self, forKey: .lat)
        lon = try c.decodeIfPresent(Double.self, forKey: .lon)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    /// Optional fields are written as explicit `null`, as documented.
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(id, forKey: .id)
        try c.encode(enteredAt, forKey: .enteredAt)
        try c.encode(date, forKey: .date)
        try c.encode(time, forKey: .time)
        try c.encode(litres, forKey: .litres)
        try c.encode(amount, forKey: .amount)
        try c.encode(rate, forKey: .rate)
        try c.encode(odometerKm, forKey: .odometerKm)
        try c.encode(fullTank, forKey: .fullTank)
        try c.encode(missed, forKey: .missed)
        try c.encode(station, forKey: .station)
        try c.encode(company, forKey: .company)
        try c.encode(lat, forKey: .lat)
        try c.encode(lon, forKey: .lon)
        try c.encode(note, forKey: .note)
    }
}

// MARK: Service

public struct Part: Codable, Equatable, Sendable {
    public var code: String
    public var name: String
    public var qty: Double
    public var unit: String?
    public var amount: Double
    public var resets: [String]

    public init(code: String, name: String, qty: Double, unit: String? = nil, amount: Double, resets: [String] = []) {
        self.code = code; self.name = name; self.qty = qty; self.unit = unit; self.amount = amount; self.resets = resets
    }

    enum CodingKeys: String, CodingKey { case code, name, qty, unit, amount, resets }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        name = try c.decode(String.self, forKey: .name)
        qty = try c.decode(Double.self, forKey: .qty)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        amount = try c.decode(Double.self, forKey: .amount)
        resets = try c.decodeIfPresent([String].self, forKey: .resets) ?? []
    }

    /// `unit` is omitted when nil (optional in the schema); `resets` is always written.
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .code)
        try c.encode(name, forKey: .name)
        try c.encode(qty, forKey: .qty)
        try c.encodeIfPresent(unit, forKey: .unit)
        try c.encode(amount, forKey: .amount)
        try c.encode(resets, forKey: .resets)
    }
}

public struct Labour: Codable, Equatable, Sendable {
    public var code: String
    public var name: String
    public var amount: Double

    public init(code: String, name: String, amount: Double) {
        self.code = code; self.name = name; self.amount = amount
    }
}

public struct ServiceVisit: Entry, Equatable {
    public static let kind = EntryKind.service
    public var schema: Int
    public var id: String
    public var enteredAt: String
    public var date: String
    public var odometerKm: Double?
    public var kindName: String?
    public var workshop: String?
    public var invoice: String?
    public var parts: [Part]
    public var labour: [Labour]
    public var partsTotal: Double?
    public var gst: Double?
    public var total: Double?
    public var notes: String?
    public var photos: [String]

    public init(schema: Int = currentSchema, id: String = newEntryID(), enteredAt: String = istTimestamp(),
                date: String, odometerKm: Double? = nil, kindName: String? = nil, workshop: String? = nil,
                invoice: String? = nil, parts: [Part] = [], labour: [Labour] = [], partsTotal: Double? = nil,
                gst: Double? = nil, total: Double? = nil, notes: String? = nil, photos: [String] = []) {
        self.schema = schema; self.id = id; self.enteredAt = enteredAt; self.date = date
        self.odometerKm = odometerKm; self.kindName = kindName; self.workshop = workshop; self.invoice = invoice
        self.parts = parts; self.labour = labour; self.partsTotal = partsTotal; self.gst = gst
        self.total = total; self.notes = notes; self.photos = photos
    }

    /// `kindName` is the JSON field `kind` (renamed because `kind` is the entry-type requirement).
    enum CodingKeys: String, CodingKey {
        case schema, id, date, kindName = "kind", workshop, invoice, parts, labour, gst, total, notes, photos
        case enteredAt = "entered_at", odometerKm = "odometer_km", partsTotal = "parts_total"
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        id = try c.decode(String.self, forKey: .id)
        enteredAt = try c.decode(String.self, forKey: .enteredAt)
        date = try c.decode(String.self, forKey: .date)
        odometerKm = try c.decodeIfPresent(Double.self, forKey: .odometerKm)
        kindName = try c.decodeIfPresent(String.self, forKey: .kindName)
        workshop = try c.decodeIfPresent(String.self, forKey: .workshop)
        invoice = try c.decodeIfPresent(String.self, forKey: .invoice)
        parts = try c.decodeIfPresent([Part].self, forKey: .parts) ?? []
        labour = try c.decodeIfPresent([Labour].self, forKey: .labour) ?? []
        partsTotal = try c.decodeIfPresent(Double.self, forKey: .partsTotal)
        gst = try c.decodeIfPresent(Double.self, forKey: .gst)
        total = try c.decodeIfPresent(Double.self, forKey: .total)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        photos = try c.decodeIfPresent([String].self, forKey: .photos) ?? []
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(id, forKey: .id)
        try c.encode(enteredAt, forKey: .enteredAt)
        try c.encode(date, forKey: .date)
        try c.encode(odometerKm, forKey: .odometerKm)
        try c.encode(kindName, forKey: .kindName)
        try c.encode(workshop, forKey: .workshop)
        try c.encode(invoice, forKey: .invoice)
        try c.encode(parts, forKey: .parts)
        try c.encode(labour, forKey: .labour)
        try c.encode(partsTotal, forKey: .partsTotal)
        try c.encode(gst, forKey: .gst)
        try c.encode(total, forKey: .total)
        try c.encode(notes, forKey: .notes)
        try c.encode(photos, forKey: .photos)
    }
}

// MARK: Maintenance

public enum MaintenanceCategory: String, Codable, CaseIterable, Sendable {
    case tyres, battery, wipers, repair, insurance, puc, wash, other

    /// Unknown categories from a newer writer read as `.other` rather than failing the whole entry.
    public init(from d: Decoder) throws {
        let raw = try d.singleValueContainer().decode(String.self)
        self = MaintenanceCategory(rawValue: raw) ?? .other
    }
}

public struct Maintenance: Entry, Equatable {
    public static let kind = EntryKind.maintenance
    public var schema: Int
    public var id: String
    public var enteredAt: String
    public var date: String
    public var odometerKm: Double?
    public var category: MaintenanceCategory
    public var cost: Double
    public var note: String?
    public var reminder: String?

    public init(schema: Int = currentSchema, id: String = newEntryID(), enteredAt: String = istTimestamp(),
                date: String, odometerKm: Double? = nil, category: MaintenanceCategory, cost: Double,
                note: String? = nil, reminder: String? = nil) {
        self.schema = schema; self.id = id; self.enteredAt = enteredAt; self.date = date
        self.odometerKm = odometerKm; self.category = category; self.cost = cost; self.note = note
        self.reminder = reminder
    }

    enum CodingKeys: String, CodingKey {
        case schema, id, date, category, cost, note, reminder
        case enteredAt = "entered_at", odometerKm = "odometer_km"
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        id = try c.decode(String.self, forKey: .id)
        enteredAt = try c.decode(String.self, forKey: .enteredAt)
        date = try c.decode(String.self, forKey: .date)
        odometerKm = try c.decodeIfPresent(Double.self, forKey: .odometerKm)
        category = try c.decode(MaintenanceCategory.self, forKey: .category)
        cost = try c.decode(Double.self, forKey: .cost)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        reminder = try c.decodeIfPresent(String.self, forKey: .reminder)
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(id, forKey: .id)
        try c.encode(enteredAt, forKey: .enteredAt)
        try c.encode(date, forKey: .date)
        try c.encode(odometerKm, forKey: .odometerKm)
        try c.encode(category, forKey: .category)
        try c.encode(cost, forKey: .cost)
        try c.encode(note, forKey: .note)
        try c.encode(reminder, forKey: .reminder)
    }
}

// MARK: storage

private func isLowercaseUUID(_ s: String) -> Bool {
    s == s.lowercased() && UUID(uuidString: s) != nil
}

/// Writes `<kind.dir>/<id>.json` atomically (pretty-printed, sorted keys).
public func save<E: Entry>(_ e: E, in book: Book) throws {
    guard isLowercaseUUID(e.id) else { throw EntryError.invalidID(e.id) }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try book.writeAtomic("\(E.kind.dir)/\(e.id).json", try enc.encode(e))
}

/// Why a file in an entry folder was not loaded.
public enum SkipReason: Equatable, Sendable {
    case newerSchema(Int)
    case unreadable(String)
    /// Not named `<lowercase-uuid>.json` (e.g. an iCloud conflict copy "<id> 2.json"): never decoded, so an
    /// entry can't appear twice.
    case badName
}

public struct SkippedEntry: Equatable, Sendable {
    public let name: String
    public let reason: SkipReason
}

/// The entries that loaded (sorted by date) and the files that were skipped, so the UI can say
/// "N entries couldn't be read" instead of losing them silently.
public struct LoadResult<E: Entry>: Sendable {
    public var entries: [E]
    public var skipped: [SkippedEntry]
}

private func decodeEntries<E: Entry>(_ type: E.Type, names: [String], read: (String) throws -> Data) throws -> LoadResult<E> {
    let dec = JSONDecoder()
    var out: [E] = []
    var skipped: [SkippedEntry] = []
    for name in names {
        guard isEntryFileName(name) else {
            skipped.append(SkippedEntry(name: name, reason: .badName))
            continue
        }
        let data = try read("\(E.kind.dir)/\(name)")
        if let probe = try? dec.decode(SchemaProbe.self, from: data), let v = probe.schema, v > currentSchema {
            skipped.append(SkippedEntry(name: name, reason: .newerSchema(v)))
            continue
        }
        do {
            let entry = try dec.decode(E.self, from: data)
            guard entry.id == String(name.dropLast(5)), isLowercaseUUID(entry.id) else {
                skipped.append(SkippedEntry(name: name, reason: .unreadable("Record ID does not match its filename")))
                continue
            }
            out.append(entry)
        } catch {
            skipped.append(SkippedEntry(name: name, reason: .unreadable(String(describing: error))))
        }
    }
    return LoadResult(entries: out.sorted { ($0.sortKey, $0.id) < ($1.sortKey, $1.id) }, skipped: skipped)
}

private extension Entry {
    var sortKey: String {
        switch self {
        case let r as Refuel: r.date + (r.time ?? "")
        case let s as ServiceVisit: s.date
        case let m as Maintenance: m.date
        default: ""
        }
    }
}

/// `<lowercase uuid>.json`, the only file names entries are saved under (same rule as the analytics bundle).
func isEntryFileName(_ name: String) -> Bool {
    name.count == 41 && name.hasSuffix(".json") && isLowercaseUUID(String(name.dropLast(5)))
}

private func entryNames(_ kind: EntryKind, _ book: Book) throws -> [String] {
    try book.list(kind.dir).filter { $0.hasSuffix(".json") }
}

/// Loads every entry of a kind, sorted by date. Entries with `schema` > 1 and unreadable files are skipped
/// and reported in `LoadResult.skipped`.
/// Throws `.notDownloaded` if an entry is still an iCloud placeholder; use the async overload to download first.
public func loadAll<E: Entry>(_ type: E.Type, from book: Book) throws -> LoadResult<E> {
    try decodeEntries(type, names: entryNames(E.kind, book)) { try book.read($0) }
}

/// Like `loadAll`, but downloads placeholders first (waiting up to `timeout` seconds each).
public func loadAll<E: Entry>(_ type: E.Type, from book: Book, timeout: TimeInterval) async throws -> LoadResult<E> {
    let names = try entryNames(E.kind, book)
    for n in names where isEntryFileName(n) { try await book.ensureDownloaded("\(E.kind.dir)/\(n)", timeout: timeout) }
    return try decodeEntries(type, names: names) { try book.read($0) }
}
