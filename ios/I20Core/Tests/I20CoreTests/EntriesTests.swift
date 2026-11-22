import Foundation
import Testing
@testable import I20Core

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct EntriesTests {
    @Test func decodeMigratedRefuel() throws {
        let r = try JSONDecoder().decode(Refuel.self, from: fixture("refuel"))
        #expect(r.schema == 1)
        #expect(r.id == "11111111-1111-4111-8111-111111111111")
        #expect(r.enteredAt == "2026-01-01T12:00:00+05:30")
        #expect(r.date == "2026-01-01")
        #expect(r.time == nil)
        #expect(r.litres == 30.0 && r.amount == 3000.0 && r.rate == 100.0)
        #expect(r.odometerKm == 10000)
        #expect(r.fullTank == nil && r.missed == false)
        #expect(r.station == "Test Pump South" && r.company == "Acme")
        #expect(r.lat == nil && r.lon == nil && r.note == nil)
    }

    @Test func decodeMigratedServiceVisit() throws {
        let s = try JSONDecoder().decode(ServiceVisit.self, from: fixture("service"))
        #expect(s.date == "2025-09-19" && s.odometerKm == 10500)
        #expect(s.kindName == "Paid service" && s.workshop == "Test Motors" && s.invoice == "INV-001")
        #expect(s.parts.count == 2)
        #expect(s.parts[0] == Part(code: "P-100", name: "Engine oil", qty: 3.6, unit: "L", amount: 1800.5, resets: ["engine_oil"]))
        #expect(s.parts[1].resets == [] && s.parts[1].unit == nil && s.parts[1].qty == 1)  // resets absent -> []
        #expect(s.labour == [Labour(code: "L-1", name: "Oil change labour", amount: 500)])
        #expect(s.partsTotal == 2150.5 && s.gst == 450.25 && s.total == 3100.75)
        #expect(s.notes == "Synthetic visit" && s.photos == [])
    }

    @Test func saveLoadRoundTripPreservesEveryField() throws {
        let (book, tmp) = try makeTempBook()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = Refuel(date: "2026-10-25", time: "18:31", litres: 30.5, amount: 3245.2, rate: 100.0,
                       odometerKm: 12000, fullTank: true, missed: true, station: "Test Pump North",
                       company: "Acme", lat: 25.3, lon: 87.1, note: "n")
        let s = try JSONDecoder().decode(ServiceVisit.self, from: fixture("service"))
        var s2 = s; s2.id = newEntryID(); s2.photos = ["a.jpg"]
        let m = Maintenance(date: "2026-10-01", odometerKm: nil, category: .puc, cost: 100, note: nil, reminder: "2027-04-01")
        try save(r, in: book); try save(s2, in: book); try save(m, in: book)
        #expect(try loadAll(Refuel.self, from: book).entries == [r])
        #expect(try loadAll(ServiceVisit.self, from: book).entries == [s2])
        #expect(try loadAll(Maintenance.self, from: book).entries == [m])
        #expect(book.exists("log/refuels/\(r.id).json"))
    }

    @Test func nullsAreWrittenExplicitly() throws {
        let r = Refuel(date: "2026-10-25", station: "X")
        let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
        for k in ["time", "litres", "amount", "rate", "odometer_km", "full_tank", "company", "lat", "lon", "note"] {
            #expect(obj[k] is NSNull, "\(k)")
        }
        #expect(obj["entered_at"] is String)
        #expect(r.id == r.id.lowercased() && UUID(uuidString: r.id) != nil)
        let e = istTimestamp(Date(timeIntervalSince1970: 0))
        #expect(e == "1970-01-01T05:30:00+05:30")
    }

    @Test func loadAllSkipsNewerSchemaAndIgnoresUnknownFields() throws {
        let (book, tmp) = try makeTempBook()
        defer { try? FileManager.default.removeItem(at: tmp) }
        var obj = try #require(JSONSerialization.jsonObject(with: fixture("refuel")) as? [String: Any])
        obj["future_field"] = 1
        let good = "11111111-1111-4111-8111-111111111111", future = "22222222-2222-4222-8222-222222222222"
        obj["id"] = good
        try book.writeAtomic("log/refuels/\(good).json", JSONSerialization.data(withJSONObject: obj))
        obj["id"] = future; obj["schema"] = 2; obj["station"] = 5  // would not even decode
        try book.writeAtomic("log/refuels/\(future).json", JSONSerialization.data(withJSONObject: obj))
        let bad = "33333333-3333-4333-8333-333333333333"
        try book.writeAtomic("log/refuels/\(bad).json", Data("not json".utf8))
        let res = try loadAll(Refuel.self, from: book)
        #expect(res.entries.map(\.id) == [good])
        let byName = Dictionary(uniqueKeysWithValues: res.skipped.map { ($0.name, $0.reason) })
        #expect(res.skipped.count == 2)
        #expect(byName["\(future).json"] == .newerSchema(2))
        if case .unreadable? = byName["\(bad).json"] {} else { Issue.record("bad file not reported unreadable") }
    }

    @Test func loadAllSkipsFilesNotNamedByUUID() throws {
        let (book, tmp) = try makeTempBook()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let obj = try fixture("refuel")
        let id = "11111111-1111-4111-8111-111111111111"
        try book.writeAtomic("log/refuels/\(id).json", obj)
        try book.writeAtomic("log/refuels/\(id) 2.json", obj)  // iCloud conflict copy of the same entry
        try book.writeAtomic("log/refuels/notes.json", obj)
        let res = try loadAll(Refuel.self, from: book)
        #expect(res.entries.count == 1)
        #expect(Set(res.skipped.map(\.name)) == ["\(id) 2.json", "notes.json"])
        #expect(res.skipped.allSatisfy { $0.reason == .badName })
    }

    @Test func loadAllOnEmptyBookAndBadIDs() throws {
        let (book, tmp) = try makeTempBook()
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(try loadAll(Refuel.self, from: book).entries.isEmpty)
        let bad = Refuel(id: "../evil", date: "2026-10-25", station: "X")
        #expect(throws: EntryError.invalidID("../evil")) { try save(bad, in: book) }
        let upper = Refuel(id: newEntryID().uppercased(), date: "2026-10-25", station: "X")
        #expect(throws: EntryError.self) { try save(upper, in: book) }
    }

    @Test func loadAllDownloadsPlaceholdersFirst() async throws {
        let (book, tmp) = try makeTempBook()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dir = book.root.appending(path: "log/refuels")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "11111111-1111-4111-8111-111111111111.json"
        try Data().write(to: dir.appending(path: ".\(name).icloud"))
        #expect(throws: BookError.notDownloaded("log/refuels/\(name)")) { try loadAll(Refuel.self, from: book).entries }
        let data = try fixture("refuel")
        _ = Task.detached {
            try await Task.sleep(for: .milliseconds(200))
            try data.write(to: dir.appending(path: name))
            try FileManager.default.removeItem(at: dir.appending(path: ".\(name).icloud"))
        }
        let loaded = try await loadAll(Refuel.self, from: book, timeout: 5)
        #expect(loaded.entries.count == 1 && loaded.skipped.isEmpty)
    }
}
