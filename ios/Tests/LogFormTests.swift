import XCTest
import UIKit
import I20Core
@testable import I20Logbook

/// Form logic of the Log tab (Task 13) against temp-dir books only — never the real iCloud book.
@MainActor
final class LogFormTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appending(path: "log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func emptyBook() throws -> Book {
        let root = tmp.appending(path: "i20_book")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Book(root: root)
    }

    /// The synthetic fixture book (3 refuels, 1 service, 2 snapshots with maintenance_alert.json).
    func fixtureBook() throws -> Book {
        let src = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "book", withExtension: nil))
        let dst = tmp.appending(path: "i20_book")
        try FileManager.default.copyItem(at: src, to: dst)
        return Book(root: dst)
    }

    /// Every file under `tmp` (to prove a failed save wrote nothing anywhere).
    func filesUnderTmp() -> [String] {
        let e = FileManager.default.enumerator(at: tmp, includingPropertiesForKeys: nil)
        return (e?.allObjects as? [URL] ?? []).map(\.path).sorted()
    }

    static let ist = TimeZone(identifier: "Asia/Kolkata")!
    func istDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = Self.ist
        return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func pastFill(_ date: String, odo: Double?, station: String = "Test Pump", company: String? = "HP",
                  lat: Double? = nil, lon: Double? = nil) -> Refuel {
        Refuel(date: date, litres: 30, amount: 3000, rate: 100, odometerKm: odo, station: station, company: company,
               lat: lat, lon: lon)
    }

    // MARK: Refuel: two-of-three, validation

    func test_amountAndRateDeriveLitres() {
        let m = RefuelFormModel(past: [])
        m.amount = "3535.67"
        m.rate = "106.40"
        XCTAssertEqual(m.derivedField, .litres)
        XCTAssertEqual(m.derivedText, "33.23")
        m.odometer = "12000"
        XCTAssertNil(m.validationMessage)
        let r = try! XCTUnwrap(m.build())
        XCTAssertNil(r.litres, "the derived value is shown, never stored (the fuel model imputes it)")
        XCTAssertEqual(r.amount, 3535.67)
        XCTAssertEqual(r.rate, 106.40)
    }

    func test_litresAndRateDeriveAmount_commaDecimal() {
        let m = RefuelFormModel(past: [])
        m.litres = "33,23"
        m.rate = "₹106.40"
        XCTAssertEqual(m.derivedField, .amount)
        XCTAssertEqual(m.derivedText, "3535.67")
    }

    func test_negativeValueBlocksSaveWithMessage() throws {
        let book = try emptyBook()
        let m = RefuelFormModel(past: [])
        m.litres = "-5"
        m.amount = "500"
        m.odometer = "12000"
        XCTAssertEqual(m.validationMessage, "Litres, amount and rate must be more than zero.")
        XCTAssertNil(m.derivedText)
        XCTAssertFalse(m.save(in: book))
        XCTAssertEqual(try book.list("log/refuels"), [])
    }

    func test_otherInputMessages() {
        let m = RefuelFormModel(past: [])
        m.odometer = "12000"
        m.amount = "500"
        XCTAssertEqual(m.validationMessage, "Enter two of litres, amount and rate.")
        m.rate = "abc"
        XCTAssertEqual(m.validationMessage, "Rate \u{201C}abc\u{201D} isn't a number.")
        m.rate = "100"
        m.litres = "9"
        XCTAssertEqual(m.validationMessage, "Litres \u{00D7} rate doesn't match the amount.")
        m.litres = ""
        m.odometer = ""
        XCTAssertEqual(m.validationMessage, "Enter the odometer reading.")
        m.odometer = "-3"
        XCTAssertEqual(m.validationMessage, "Odometer must be more than zero.")
    }

    func test_missedFillNeedsOnlyTheDate() throws {
        let book = try emptyBook()
        let m = RefuelFormModel(past: [], now: istDate(2026, 10, 20, 9, 15))
        m.missed = true
        XCTAssertNil(m.validationMessage)
        m.setLocation(lat: 12.9, lon: 77.5)
        XCTAssertTrue(m.save(in: book))
        let r = try XCTUnwrap(loadAll(Refuel.self, from: book).entries.first)
        XCTAssertTrue(r.missed)
        XCTAssertEqual(r.date, "2026-10-20")
        XCTAssertNil(r.litres); XCTAssertNil(r.amount); XCTAssertNil(r.rate); XCTAssertNil(r.odometerKm)
        // The phone isn't at the pump for a fill logged after the fact.
        XCTAssertNil(r.lat); XCTAssertNil(r.lon)
    }

    func test_missedFillDefaultsTankToNotRecordedUnlessChosen() {
        let m = RefuelFormModel(past: [])
        XCTAssertEqual(m.fullTank, true)
        m.missed = true
        XCTAssertNil(m.fullTank)
        XCTAssertTrue(m.offersUnknownTank)
        m.missed = false
        XCTAssertEqual(m.fullTank, true)

        let chosen = RefuelFormModel(past: [])
        chosen.chooseTank(false)
        chosen.missed = true
        XCTAssertEqual(chosen.fullTank, false, "an explicit choice survives")

        let edited = RefuelFormModel(editing: Refuel(id: newEntryID(), date: "2026-10-20", fullTank: true, station: "X"), past: [])
        edited.missed = true
        XCTAssertEqual(edited.fullTank, true, "editing keeps the stored value")
    }

    func test_missedFillStillRejectsNonsense() {
        let m = RefuelFormModel(past: [])
        m.missed = true
        m.litres = "-2"
        XCTAssertEqual(m.validationMessage, "Litres, amount and rate must be more than zero.")
        m.litres = "20"
        XCTAssertNil(m.validationMessage)
        XCTAssertEqual(m.build()?.litres, 20)
        XCTAssertNil(m.build()?.amount)
    }

    // MARK: Refuel: odometer warning

    func test_odometerBelowPreviousFillWarnsButSaves() throws {
        let book = try emptyBook()
        let m = RefuelFormModel(past: [pastFill("2026-10-10", odo: 11044), pastFill("2026-10-01", odo: 10500)],
                                now: istDate(2026, 10, 20, 8, 0))
        m.amount = "3000"; m.rate = "100"
        m.odometer = "11000"
        XCTAssertEqual(m.odometerWarning, "Odometer 11000 km is lower than the previous fill (11044 km).")
        XCTAssertNil(m.validationMessage)
        XCTAssertTrue(m.save(in: book))
        XCTAssertEqual(try book.list("log/refuels").count, 1)
        m.odometer = "11100"
        XCTAssertNil(m.odometerWarning)
    }

    func test_previousFillIsTheLatestBeforeThisDateAndNotItself() {
        let earlier = pastFill("2026-10-01", odo: 10500)
        let later = pastFill("2026-10-25", odo: 12000)
        let me = pastFill("2026-10-10", odo: 11000)
        let m = RefuelFormModel(editing: me, past: [earlier, later, me])
        XCTAssertEqual(m.previousOdometer, 10500)
        m.odometer = "10400"
        XCTAssertNotNil(m.odometerWarning)
    }

    // MARK: Refuel: save

    func test_saveWritesOneFileWithTheFormValues() throws {
        let book = try emptyBook()
        let m = RefuelFormModel(past: [], now: istDate(2026, 10, 26, 18, 31))
        XCTAssertEqual(m.fullTank, true, "Full tank defaults on")
        XCTAssertFalse(m.offersUnknownTank)
        m.litres = "30"; m.amount = "3000"
        m.odometer = "12,345"
        m.station = "  Shell Koramangala "
        m.company = "Shell"
        m.note = "after trip"
        m.setLocation(lat: 12.93, lon: 77.62)
        XCTAssertTrue(m.save(in: book))
        XCTAssertNil(m.saveError)
        XCTAssertEqual(try book.list("log/refuels"), ["\(m.id).json"])
        let r = try XCTUnwrap(loadAll(Refuel.self, from: book).entries.first)
        XCTAssertEqual(r.id, m.id)
        XCTAssertEqual(r.date, "2026-10-26")
        XCTAssertEqual(r.time, "18:31")
        XCTAssertEqual(r.litres, 30); XCTAssertEqual(r.amount, 3000); XCTAssertNil(r.rate)
        XCTAssertEqual(r.odometerKm, 12345)
        XCTAssertEqual(r.fullTank, true)
        XCTAssertFalse(r.missed)
        XCTAssertEqual(r.station, "Shell Koramangala")
        XCTAssertEqual(r.company, "Shell")
        XCTAssertEqual(r.note, "after trip")
        XCTAssertEqual(r.lat, 12.93); XCTAssertEqual(r.lon, 77.62)
        XCTAssertNotNil(r.enteredAt.range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\+05:30$"#, options: .regularExpression))
    }

    func test_emptyOptionalTextIsNull() throws {
        let m = RefuelFormModel(past: [])
        m.litres = "30"; m.amount = "3000"; m.odometer = "100"
        let r = try XCTUnwrap(m.build())
        XCTAssertEqual(r.station, "")
        XCTAssertNil(r.company)
        XCTAssertNil(r.note)
    }

    func test_saveFailsVisiblyWhenTheBookFolderIsGone() throws {
        let book = try emptyBook()
        try FileManager.default.removeItem(at: book.root)
        let before = filesUnderTmp()
        let m = RefuelFormModel(past: [])
        m.litres = "30"; m.amount = "3000"; m.odometer = "100"
        XCTAssertFalse(m.save(in: book))
        XCTAssertEqual(m.saveError, "Couldn't save to iCloud Drive (i20_book). Nothing was saved.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.root.path), "root must not be recreated")
        XCTAssertEqual(filesUnderTmp(), before, "nothing written anywhere")
    }

    func test_saveFailsWhenNoFolderIsChosen() {
        let m = RefuelFormModel(past: [])
        m.litres = "30"; m.amount = "3000"; m.odometer = "100"
        XCTAssertFalse(m.save(in: nil))
        XCTAssertEqual(m.saveError, LogText.saveFailed)
    }

    func test_editKeepsTheSameIdAndFile() throws {
        let book = try emptyBook()
        let m = RefuelFormModel(past: [], now: istDate(2026, 10, 26, 7, 5))
        m.litres = "30"; m.amount = "3000"; m.rate = "100"; m.odometer = "100"
        XCTAssertTrue(m.save(in: book))
        let saved = try XCTUnwrap(loadAll(Refuel.self, from: book).entries.first)

        let e = RefuelFormModel(editing: saved, past: [saved])
        XCTAssertEqual(e.litres, "30"); XCTAssertEqual(e.amount, "3000"); XCTAssertEqual(e.rate, "100")
        XCTAssertEqual(e.odometer, "100")
        e.rate = ""
        e.amount = "3150"
        XCTAssertTrue(e.save(in: book))
        XCTAssertEqual(try book.list("log/refuels"), ["\(saved.id).json"])
        let after = try XCTUnwrap(loadAll(Refuel.self, from: book).entries.first)
        XCTAssertEqual(after.id, saved.id)
        XCTAssertEqual(after.enteredAt, saved.enteredAt)
        XCTAssertEqual(after.amount, 3150)
        XCTAssertEqual(after.litres, 30)
        XCTAssertNil(after.rate)
        XCTAssertEqual(after.date, "2026-10-26")
        XCTAssertEqual(after.time, "07:05")
    }

    func test_editKeepsUnknownTimeAndCoordinates() throws {
        let migrated = Refuel(date: "2025-11-19", litres: 35, amount: 3500, rate: 100, odometerKm: 9000,
                              station: "Test Pump", company: "HP", lat: 1, lon: 2)
        let e = RefuelFormModel(editing: migrated, past: [migrated])
        XCTAssertNil(e.fullTank, "an unknown full_tank stays visibly unknown")
        XCTAssertTrue(e.offersUnknownTank)
        e.setLocation(lat: 50, lon: 60)  // where the phone is now: ignored when editing
        let r = try XCTUnwrap(e.build())
        XCTAssertNil(r.time)
        XCTAssertEqual(r.date, "2025-11-19")
        XCTAssertNil(r.fullTank, "unchanged unknown stays unknown")
        XCTAssertEqual(r.lat, 1); XCTAssertEqual(r.lon, 2)
    }

    func test_resavingKeepsStoredNullsAndOnlyTypedValues() throws {
        let book = try emptyBook()
        let old = Refuel(date: "2025-11-19", litres: 30, amount: 3000, rate: nil, odometerKm: 9000, station: "P")
        try save(old, in: book)
        let e = RefuelFormModel(editing: old, past: [old])
        XCTAssertEqual(e.derivedText, "100", "shown live")
        e.note = "receipt lost"
        XCTAssertTrue(e.save(in: book))
        let r = try XCTUnwrap(loadAll(Refuel.self, from: book).entries.first)
        XCTAssertNil(r.rate)
        XCTAssertEqual(r.note, "receipt lost")
    }

    func test_oldEntryWithSoftProblemsStaysEditableUntilThoseFieldsChange() throws {
        let book = try emptyBook()
        // Migrated row: litres x rate is 3600 vs amount 3000 (inconsistent) and no odometer.
        let old = Refuel(date: "2025-11-19", litres: 30, amount: 3000, rate: 120, odometerKm: nil, station: "P")
        let e = RefuelFormModel(editing: old, past: [old])
        XCTAssertNil(e.validationMessage)
        XCTAssertEqual(e.warningMessage, "Litres \u{00D7} rate doesn't match the amount.")
        e.note = "fixed station"
        XCTAssertTrue(e.save(in: book))
        e.amount = "3100"
        XCTAssertEqual(e.validationMessage, "Litres \u{00D7} rate doesn't match the amount.")
        XCTAssertNil(e.warningMessage)
        XCTAssertFalse(e.save(in: book))
        e.amount = "3600"
        XCTAssertEqual(e.validationMessage, "Enter the odometer reading.", "changed fuel fields: odometer now required")

        let noOdo = Refuel(date: "2025-11-20", litres: 30, amount: 3000, rate: 100, odometerKm: nil, station: "P")
        let f = RefuelFormModel(editing: noOdo, past: [noOdo])
        XCTAssertNil(f.validationMessage)
        XCTAssertEqual(f.warningMessage, "Enter the odometer reading.")
        XCTAssertTrue(f.save(in: book))
        // Bad input still blocks on an old entry.
        f.odometer = "-5"
        XCTAssertEqual(f.validationMessage, "Odometer must be more than zero.")
    }

    func test_tankThreeStateOnEditOfUnknown() throws {
        let book = try emptyBook()
        let old = Refuel(date: "2025-11-19", litres: 30, amount: 3000, rate: 100, odometerKm: 9000, fullTank: nil, station: "P")
        try save(old, in: book)
        let e = RefuelFormModel(editing: old, past: [old])
        XCTAssertTrue(e.save(in: book))
        XCTAssertNil(try loadAll(Refuel.self, from: book).entries.first?.fullTank, "null round-trips")
        let p = RefuelFormModel(editing: old, past: [old])
        p.fullTank = false
        XCTAssertTrue(p.save(in: book))
        XCTAssertEqual(try loadAll(Refuel.self, from: book).entries.first?.fullTank, false, "Partial can be set")
        let known = try XCTUnwrap(loadAll(Refuel.self, from: book).entries.first)
        XCTAssertFalse(RefuelFormModel(editing: known, past: []).offersUnknownTank)
    }

    // MARK: Refuel: stations

    func test_stationSuggestionsAndCompanyFromLastFill() {
        let past = [pastFill("2026-09-01", odo: 1, station: "Test Pump", company: "BPCL"),
                    pastFill("2026-10-01", odo: 2, station: "Test Pump", company: "HP"),
                    pastFill("2026-10-02", odo: 3, station: "Other Pump", company: "IOCL")]
        let m = RefuelFormModel(past: past)
        m.station = "oth"
        XCTAssertEqual(m.suggestions.first, "Other Pump")
        m.chooseStation("Test Pump")
        XCTAssertEqual(m.station, "Test Pump")
        XCTAssertEqual(m.company, "HP")
        m.chooseStation("New Pump")  // no history: company left as typed
        XCTAssertEqual(m.company, "HP")
    }

    // MARK: Service

    func test_maintenanceItemsFromTheLatestAlert() throws {
        let book = try fixtureBook()
        let items = MaintenanceItems.latest(in: book)
        XCTAssertEqual(items.names, ["Engine oil", "Air Cleaner"])
        XCTAssertNil(items.note)
    }

    func test_maintenanceItemsMissingOrPlaceholderShowsANote() throws {
        let book = try emptyBook()
        var items = MaintenanceItems.latest(in: book)
        XCTAssertEqual(items.names, [])
        XCTAssertEqual(items.note, MaintenanceItems.unavailableNote)

        let dir = book.root.appending(path: "raw/snapshots/v1/20261010T100000")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appending(path: ".maintenance_alert.json.icloud"))
        items = MaintenanceItems.latest(in: book)
        XCTAssertEqual(items.names, [])
        XCTAssertEqual(items.note, MaintenanceItems.unavailableNote)
    }

    func test_newestSnapshotWithAnAlertWins() throws {
        let book = try fixtureBook()
        let vid = "00000000-0000-4000-8000-000000000001"
        // A newer snapshot without maintenance_alert.json is passed over.
        try book.writeAtomic("raw/snapshots/\(vid)/20261006T200000/status_latest.json", Data("{}".utf8))
        let alert = #"{"retCode":"S","resMsg":{"mainList":[{"itemId":"Brake fluid"}]}}"#
        try book.writeAtomic("raw/snapshots/\(vid)/20261001T200000/maintenance_alert.json", Data(alert.utf8))
        XCTAssertEqual(MaintenanceItems.latest(in: book).names, ["Engine oil", "Air Cleaner"])
        try book.writeAtomic("raw/snapshots/\(vid)/20261007T200000/maintenance_alert.json", Data(alert.utf8))
        XCTAssertEqual(MaintenanceItems.latest(in: book).names, ["Brake fluid"])
    }

    func test_serviceTotalIsPreSummedAndEditable() {
        let m = ServiceFormModel(resetChoices: [])
        m.addPart()
        m.parts[0].name = "Engine oil"; m.parts[0].amount = "1500"
        m.addLabour()
        m.labour[0].name = "Labour"; m.labour[0].amount = "400"
        m.gst = "270"
        XCTAssertEqual(m.totalText, "2170")
        m.totalText = "2200"
        m.gst = "300"
        XCTAssertEqual(m.totalText, "2200", "an edited total is kept")
        let s = m.build()
        XCTAssertEqual(s?.total, 2200)
        XCTAssertEqual(s?.partsTotal, 1500)
        XCTAssertEqual(s?.gst, 300)
    }

    func test_resetsFromServiceMapToItemNames() throws {
        let book = try fixtureBook()
        let items = MaintenanceItems.latest(in: book)
        let m = ServiceFormModel(resetChoices: items.names, now: istDate(2026, 10, 4, 11))
        m.odometer = "1300"
        m.kindName = "Paid service"
        m.workshop = "Test Motors"
        m.addPart()
        m.parts[0].name = "Oil"; m.parts[0].code = "P-9"; m.parts[0].qty = "3.5"; m.parts[0].amount = "1600"
        m.parts[0].resets = ["Engine oil"]
        XCTAssertEqual(m.resetChoices, ["Engine oil", "Air Cleaner"])
        XCTAssertTrue(m.save(in: book))
        let s = try XCTUnwrap(loadAll(ServiceVisit.self, from: book).entries.first { $0.id == m.id })
        XCTAssertEqual(s.date, "2026-10-04")
        XCTAssertEqual(s.odometerKm, 1300)
        XCTAssertEqual(s.kindName, "Paid service")
        XCTAssertEqual(s.parts, [Part(code: "P-9", name: "Oil", qty: 3.5, amount: 1600, resets: ["Engine oil"])])
    }

    func test_serviceValidation() {
        let m = ServiceFormModel(resetChoices: ["Engine oil"])
        XCTAssertNil(m.validationMessage, "a visit with only a date is valid")
        m.addPart()
        m.parts[0].amount = "100"
        XCTAssertEqual(m.validationMessage, "Every part needs a name.")
        m.parts[0].name = "Filter"
        m.parts[0].amount = "-1"
        XCTAssertEqual(m.validationMessage, "Amounts can't be negative.")
        m.parts[0].amount = "100"
        m.parts[0].resets = ["Engine oil"]
        XCTAssertEqual(m.validationMessage, "Enter the odometer: a part resets a maintenance item.")
        m.odometer = "1300"
        XCTAssertNil(m.validationMessage)
        m.gst = "x"
        XCTAssertEqual(m.validationMessage, "GST \u{201C}x\u{201D} isn't a number.")
        m.gst = ""
        m.addPart()  // blank rows are dropped, not errors
        XCTAssertNil(m.validationMessage)
        XCTAssertEqual(m.build()?.parts.count, 1)
        XCTAssertEqual(m.build()?.parts.first?.qty, 1, "qty defaults to 1")
    }

    func test_oldServiceResettingWithoutOdometerStaysEditable() throws {
        let book = try emptyBook()
        let old = ServiceVisit(date: "2026-09-19", odometerKm: nil,
                               parts: [Part(code: "P", name: "Oil", qty: 1, amount: 100, resets: ["Engine oil"])])
        let m = ServiceFormModel(editing: old, resetChoices: ["Engine oil", "Air Cleaner"])
        XCTAssertNil(m.validationMessage)
        XCTAssertEqual(m.warningMessage, "Enter the odometer: a part resets a maintenance item.")
        m.notes = "x"
        XCTAssertTrue(m.save(in: book))
        m.parts[0].resets.insert("Air Cleaner")
        XCTAssertEqual(m.validationMessage, "Enter the odometer: a part resets a maintenance item.")
        XCTAssertFalse(m.save(in: book))
    }

    func test_saveWaitsForLoadingPhotosAndReportsBadOnes() throws {
        let book = try emptyBook()
        let m = ServiceFormModel(resetChoices: [])
        m.photoLoadStarted()
        m.photoLoadStarted()
        XCTAssertFalse(m.canSave)
        XCTAssertFalse(m.save(in: book))
        XCTAssertEqual(try book.list("log/services"), [])
        m.photoLoaded(nil)
        XCTAssertEqual(m.photoError, ServiceFormModel.photoFailed)
        XCTAssertFalse(m.canSave)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { _ in }
        m.photoLoaded(png)
        XCTAssertTrue(m.canSave)
        XCTAssertEqual(m.photos.count, 1)
        XCTAssertTrue(m.save(in: book))
    }

    func test_failedDeleteOfARemovedPhotoIsAWarning() throws {
        let book = try emptyBook()
        let m = ServiceFormModel(resetChoices: [])
        m.addPhoto(Data([0xFF, 0xD8, 0xFF]))
        XCTAssertTrue(m.save(in: book))
        let s = try XCTUnwrap(loadAll(ServiceVisit.self, from: book).entries.first)
        let dir = book.root.appending(path: "log/services/\(s.id)")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let e = ServiceFormModel(editing: s, resetChoices: [])
        e.removePhoto(s.photos[0])
        XCTAssertTrue(e.save(in: book))
        XCTAssertEqual(e.cleanupWarning, ServiceFormModel.photoNotDeleted)
        XCTAssertEqual(try loadAll(ServiceVisit.self, from: book).entries.first?.photos, [])
    }

    func test_editServiceKeepsIdAndOldResets() throws {
        let book = try fixtureBook()
        let old = try XCTUnwrap(loadAll(ServiceVisit.self, from: book).entries.first)
        let m = ServiceFormModel(editing: old, resetChoices: ["Engine oil"])
        XCTAssertEqual(m.resetChoices, ["Engine oil", "engine_oil"], "a stored reset stays choosable")
        XCTAssertEqual(m.totalText, "2170")
        m.notes = "edited"
        XCTAssertTrue(m.save(in: book))
        XCTAssertEqual(try book.list("log/services"), ["\(old.id).json"])
        let s = try XCTUnwrap(loadAll(ServiceVisit.self, from: book).entries.first)
        var expected = old
        expected.notes = "edited"
        XCTAssertEqual(s, expected)
    }

    func test_photosAreSavedAsJPEGInTheServiceFolder() throws {
        let book = try emptyBook()
        let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let jpeg = try XCTUnwrap(ServiceFormModel.jpeg(from: png))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
        XCTAssertNil(ServiceFormModel.jpeg(from: Data("not an image".utf8)))

        let m = ServiceFormModel(resetChoices: [])
        m.addPhoto(jpeg)
        XCTAssertTrue(m.save(in: book))
        let s = try XCTUnwrap(loadAll(ServiceVisit.self, from: book).entries.first)
        XCTAssertEqual(s.photos.count, 1)
        XCTAssertTrue(s.photos[0].hasSuffix(".jpg"))
        XCTAssertEqual(try book.read("log/services/\(m.id)/\(s.photos[0])"), jpeg)

        // Removing a photo on edit deletes its file once the entry is saved.
        let e = ServiceFormModel(editing: s, resetChoices: [])
        e.removePhoto(s.photos[0])
        XCTAssertTrue(e.save(in: book))
        XCTAssertEqual(try loadAll(ServiceVisit.self, from: book).entries.first?.photos, [])
        XCTAssertFalse(book.exists("log/services/\(m.id)/\(s.photos[0])"))
    }

    func test_serviceSaveFailureWritesNothing() throws {
        let book = try emptyBook()
        try FileManager.default.removeItem(at: book.root)
        let before = filesUnderTmp()
        let m = ServiceFormModel(resetChoices: [])
        m.addPhoto(Data([0xFF, 0xD8, 0xFF]))
        XCTAssertFalse(m.save(in: book))
        XCTAssertEqual(m.saveError, LogText.saveFailed)
        XCTAssertEqual(filesUnderTmp(), before)
    }

    func test_serviceEntryFailureRemovesThePhotosItWrote() throws {
        let book = try emptyBook()
        let m = ServiceFormModel(resetChoices: [])
        m.addPhoto(Data([0xFF, 0xD8, 0xFF]))
        // A folder where the entry file must go makes the entry write fail after the photos were written.
        try FileManager.default.createDirectory(at: book.root.appending(path: "log/services/\(m.id).json/x"),
                                                withIntermediateDirectories: true)
        XCTAssertFalse(m.save(in: book))
        XCTAssertEqual(m.saveError, LogText.saveFailed)
        XCTAssertEqual(try book.list("log/services/\(m.id)"), [])
    }

    /// Manual check 7: a service with "Engine oil" in resets moves the Overview's engine-oil due date.
    func test_engineOilResetMovesTheOverviewDueDate() async throws {
        let book = try fixtureBook()
        let runner = AnalyticsRunner(derivedDir: tmp.appending(path: "derived"))
        func engineOil() async throws -> [String: Any] {
            let out = try await runner.run(book: book, today: "2026-10-06")
            let data = try XCTUnwrap(try JSONSerialization.jsonObject(with: out.data) as? [String: Any])
            let plan = try XCTUnwrap(data["service"] as? [[String: Any]])
            return try XCTUnwrap(plan.first { $0["item"] as? String == "Engine oil" })
        }
        let before = try await engineOil()
        XCTAssertTrue(before["last_done"] is NSNull)

        let m = ServiceFormModel(resetChoices: MaintenanceItems.latest(in: book).names,
                                 now: istDate(2026, 10, 4, 11))
        m.odometer = "1300"
        m.addPart()
        m.parts[0].name = "Engine oil"; m.parts[0].amount = "1600"; m.parts[0].resets = ["Engine oil"]
        XCTAssertTrue(m.save(in: book))

        let after = try await engineOil()
        let last = try XCTUnwrap(after["last_done"] as? [String: Any])
        XCTAssertEqual(last["date"] as? String, "2026-10-04")
        XCTAssertEqual(last["km"] as? Double, 1300)
        XCTAssertEqual(after["km_due"] as? Double, 11300)
        XCTAssertNotEqual(after["due"] as? String, before["due"] as? String)
    }

    // MARK: Maintenance

    func test_maintenanceValidationAndSave() throws {
        let book = try emptyBook()
        let m = MaintenanceFormModel(now: istDate(2026, 10, 26, 10))
        XCTAssertEqual(m.validationMessage, "Enter the cost.")
        m.cost = "-100"
        XCTAssertEqual(m.validationMessage, "Cost can't be negative.")
        m.cost = "1,200"
        m.odometer = "-1"
        XCTAssertEqual(m.validationMessage, "Odometer must be more than zero.")
        m.odometer = ""
        m.category = .puc
        m.note = "PUC renewal"
        m.hasReminder = true
        m.reminder = istDate(2027, 4, 26)
        XCTAssertNil(m.validationMessage)
        XCTAssertTrue(m.save(in: book))
        let e = try XCTUnwrap(loadAll(Maintenance.self, from: book).entries.first)
        XCTAssertEqual(e, Maintenance(id: m.id, enteredAt: e.enteredAt, date: "2026-10-26", odometerKm: nil,
                                      category: .puc, cost: 1200, note: "PUC renewal", reminder: "2027-04-26"))

        let edit = MaintenanceFormModel(editing: e)
        XCTAssertTrue(edit.hasReminder)
        edit.hasReminder = false
        XCTAssertTrue(edit.save(in: book))
        XCTAssertEqual(try book.list("log/maintenance"), ["\(e.id).json"])
        XCTAssertNil(try loadAll(Maintenance.self, from: book).entries.first?.reminder)
    }

    func test_maintenanceSaveFailure() throws {
        let book = try emptyBook()
        try FileManager.default.removeItem(at: book.root)
        let m = MaintenanceFormModel()
        m.cost = "500"
        XCTAssertFalse(m.save(in: book))
        XCTAssertEqual(m.saveError, LogText.saveFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.root.path))
    }

    // MARK: List

    func test_listIsNewestFirstAndFilters() async throws {
        let book = try fixtureBook()
        try save(Maintenance(date: "2026-10-04", category: .wash, cost: 300), in: book)
        try save(Refuel(date: "2026-10-05", time: "18:00", litres: 5, amount: 500, rate: 100, station: "Late"), in: book)
        let store = LogStore()
        await store.load(from: book)
        XCTAssertNil(store.loadError)
        let all = store.visible(.all)
        XCTAssertEqual(all.map(\.date), ["2026-10-05", "2026-10-05", "2026-10-04", "2026-10-03", "2026-10-02", "2026-10-01"])
        guard case .refuel(let first) = all[0] else { return XCTFail("timed fill first") }
        XCTAssertEqual(first.station, "Late")
        XCTAssertEqual(store.visible(.fuel).count, 4)
        XCTAssertEqual(store.visible(.service).count, 1)
        XCTAssertEqual(store.visible(.other).count, 1)
        XCTAssertEqual(store.refuels.count, 4)
    }

    func test_loadReportsAnUnreachableFolder() async throws {
        let book = try emptyBook()
        try FileManager.default.removeItem(at: book.root)
        let store = LogStore()
        await store.load(from: book)
        XCTAssertEqual(store.loadError, LogText.loadFailed)
        XCTAssertEqual(store.items.count, 0)
    }

    func test_deleteRemovesTheEntryAndAServicePhotoFolder() async throws {
        let book = try emptyBook()
        let m = ServiceFormModel(resetChoices: [])
        m.addPhoto(Data([0xFF, 0xD8, 0xFF]))
        XCTAssertTrue(m.save(in: book))
        let store = LogStore()
        await store.load(from: book)
        let item = try XCTUnwrap(store.items.first)
        XCTAssertTrue(store.delete(item, in: book))
        XCTAssertEqual(try book.list("log/services"), [])
        XCTAssertTrue(store.items.isEmpty)
    }

    func test_deleteRemovesAPhotoFolderHoldingPlaceholders() async throws {
        let book = try emptyBook()
        let s = ServiceVisit(date: "2026-10-01")
        try save(s, in: book)
        let dir = book.root.appending(path: "log/services/\(s.id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appending(path: ".a.jpg.icloud"))
        let store = LogStore()
        await store.load(from: book)
        XCTAssertTrue(store.delete(try XCTUnwrap(store.items.first), in: book))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func test_deleteFailureIsReported() async throws {
        let book = try emptyBook()
        try save(Maintenance(date: "2026-10-04", category: .wash, cost: 300), in: book)
        let store = LogStore()
        await store.load(from: book)
        try FileManager.default.removeItem(at: book.root)
        XCTAssertFalse(store.delete(try XCTUnwrap(store.items.first), in: book))
        XCTAssertEqual(store.actionError, LogText.deleteFailed)
        XCTAssertEqual(store.items.count, 1)
    }

    /// Manual check 5 (the data half): a saved refuel reaches the Fuel page's data after the rebuild.
    func test_savedRefuelReachesTheFuelPageAfterRebuild() async throws {
        let book = try fixtureBook()
        let derived = tmp.appending(path: "derived")
        let sync = SyncCoordinator(book: { book }, credentials: { nil },
                                   runner: AnalyticsRunner(derivedDir: derived), now: { self.istDate(2026, 10, 6, 12) })
        let m = RefuelFormModel(past: [], now: istDate(2026, 10, 4, 9, 30))
        m.amount = "1234"; m.rate = "100"; m.odometer = "1300"; m.station = "Fresh Pump"
        XCTAssertTrue(m.save(in: book))
        await LogStore.rebuildAfterSave(sync)
        XCTAssertNil(sync.state.error)
        let fuel = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: derived.appending(path: "fuel.json"))) as? [String: Any])
        let fills = try XCTUnwrap(fuel["fills"] as? [[String: Any]])
        XCTAssertTrue(fills.contains { $0["station"] as? String == "Fresh Pump" && $0["amount"] as? Double == 1234 })
    }
}
