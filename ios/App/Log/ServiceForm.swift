import SwiftUI
import PhotosUI
import UIKit
import I20Core

/// The Bluelink maintenance item names (e.g. "Engine oil") a service part can reset, from the newest
/// `raw/snapshots/<vid>/<ts>/maintenance_alert.json` in the book.
enum MaintenanceItems {
    static let unavailableNote = "No Bluelink maintenance list yet (or it's still downloading from iCloud) \u{2014} sync, then tag what this visit reset."

    /// Blocking file I/O: call off the main thread (`ServiceForm` loads it in a detached task).
    static func latest(in book: Book?) -> (names: [String], note: String?) {
        let none: ([String], String?) = ([], unavailableNote)
        guard let book, let vids = try? book.list("raw/snapshots") else { return none }
        let snapshots = vids.flatMap { vid in ((try? book.list("raw/snapshots/\(vid)")) ?? []).map { (ts: $0, vid: vid) } }
        // Newest first; stop at the first snapshot that has an alert.
        let newest = snapshots.sorted { $0.ts > $1.ts }.lazy
            .map { "raw/snapshots/\($0.vid)/\($0.ts)/maintenance_alert.json" }
            .first { book.exists($0) }
        struct Alert: Decodable {
            struct Msg: Decodable { let mainList: [Item]? }
            struct Item: Decodable { let itemId: String? }
            let resMsg: Msg?
        }
        guard let path = newest, let data = try? book.read(path),
              let alert = try? JSONDecoder().decode(Alert.self, from: data) else { return none }
        let names = (alert.resMsg?.mainList ?? []).compactMap(\.itemId)
        return names.isEmpty ? none : (names, nil)
    }
}

struct PartRow: Identifiable {
    let id = UUID()
    var code = ""
    var name = ""
    var qty = ""
    var unit: String?
    var amount = ""
    var resets: Set<String> = []

    var isBlank: Bool {
        [code, name, qty, amount].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } && resets.isEmpty
    }
}

struct LabourRow: Identifiable {
    let id = UUID()
    var code = ""
    var name = ""
    var amount = ""

    var isBlank: Bool { [code, name, amount].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
}

/// Service visit form logic: visit fields, parts and labour rows (each part can reset Bluelink maintenance
/// items), GST, a pre-summed editable total, notes and JPEG photos in `log/services/<id>/`.
@MainActor
final class ServiceFormModel: ObservableObject {
    let id: String
    let isEditing: Bool
    private let original: ServiceVisit?
    /// Item names a part can reset: the latest Bluelink list plus any already stored on this entry.
    @Published private(set) var resetChoices: [String] = []
    @Published private(set) var resetNote: String?
    /// Odometer and resets as loaded, so the resets-need-odometer check doesn't block re-saving an old entry.
    private var initialResetFields = ""

    @Published var date: Date
    @Published var odometer = ""
    @Published var kindName = ""
    @Published var workshop = ""
    @Published var invoice = ""
    @Published var parts: [PartRow] = []
    @Published var labour: [LabourRow] = []
    @Published var gst = ""
    @Published var notes = ""
    @Published private var totalOverride: String?
    @Published private var existingPhotos: [String] = []
    @Published private var newPhotos: [(name: String, data: Data)] = []
    @Published var saveError: String?
    /// Photos still being loaded from the picker (Save waits for them).
    @Published private(set) var photosLoading = 0
    /// A picked item that couldn't be read as an image.
    @Published var photoError: String?
    /// Set by a successful save when a removed photo couldn't be deleted (non-blocking).
    @Published private(set) var cleanupWarning: String?

    static let photoFailed = "A photo couldn't be added (not an image, or it couldn't be loaded)."
    static let photoNotDeleted = "Saved, but a removed photo couldn't be deleted from iCloud Drive (i20_book)."

    init(resetChoices: [String], resetNote: String? = nil, now: Date = Date()) {
        id = newEntryID()
        isEditing = false
        original = nil
        date = now
        setMaintenance(names: resetChoices, note: resetNote)
    }

    init(editing s: ServiceVisit, resetChoices: [String], resetNote: String? = nil) {
        id = s.id
        isEditing = true
        original = s
        date = ISTClock.date(day: s.date) ?? Date()
        odometer = plainNumber(s.odometerKm)
        kindName = s.kindName ?? ""
        workshop = s.workshop ?? ""
        invoice = s.invoice ?? ""
        parts = s.parts.map {
            PartRow(code: $0.code, name: $0.name, qty: plainNumber($0.qty), unit: $0.unit, amount: plainNumber($0.amount),
                    resets: Set($0.resets))
        }
        labour = s.labour.map { LabourRow(code: $0.code, name: $0.name, amount: plainNumber($0.amount)) }
        gst = plainNumber(s.gst)
        notes = s.notes ?? ""
        totalOverride = s.total.map(plainNumber)
        existingPhotos = s.photos
        setMaintenance(names: resetChoices, note: resetNote)
        initialResetFields = resetFields
    }

    /// The latest Bluelink item names (plus resets already stored on this entry).
    func setMaintenance(names: [String], note: String?) {
        var choices = names
        for r in (original?.parts ?? []).flatMap(\.resets) where !choices.contains(r) { choices.append(r) }
        resetChoices = choices
        resetNote = note
    }

    private var resetFields: String {
        odometer + "|" + parts.filter { !$0.isBlank }.map { $0.resets.sorted().joined(separator: ",") }.joined(separator: ";")
    }

    func addPart() { parts.append(PartRow()) }
    func addLabour() { labour.append(LabourRow()) }

    // MARK: totals

    private var partsSum: Double { parts.compactMap { Typed($0.amount).value }.reduce(0, +) }
    private var labourSum: Double { labour.compactMap { Typed($0.amount).value }.reduce(0, +) }

    /// Parts + labour + GST, while the owner hasn't typed a total of their own.
    var totalText: String {
        get {
            if let totalOverride { return totalOverride }
            let sum = partsSum + labourSum + (Typed(gst).value ?? 0)
            let anything = !parts.allSatisfy(\.isBlank) || !labour.allSatisfy(\.isBlank) || Typed(gst) != .empty
            return anything ? plainNumber(round2(sum)) : ""
        }
        set { totalOverride = newValue.trimmingCharacters(in: .whitespaces).isEmpty ? nil : newValue }
    }

    var partsTotalText: String { plainNumber(round2(partsSum)) }
    var labourTotalText: String { plainNumber(round2(labourSum)) }

    // MARK: photos

    var photos: [String] { existingPhotos + newPhotos.map(\.name) }

    func newPhotoData(_ name: String) -> Data? { newPhotos.first { $0.name == name }?.data }

    func addPhoto(_ jpeg: Data) {
        newPhotos.append(("\(UUID().uuidString.lowercased().prefix(8)).jpg", jpeg))
    }

    func photoLoadStarted() { photosLoading += 1 }

    /// A picked item finished loading: its bytes (nil if loading failed), re-encoded as JPEG here.
    func photoLoaded(_ data: Data?) {
        photosLoading = max(0, photosLoading - 1)
        if let data, let jpeg = Self.jpeg(from: data) { addPhoto(jpeg) } else { photoError = Self.photoFailed }
    }

    var canSave: Bool { validationMessage == nil && photosLoading == 0 }

    func removePhoto(_ name: String) {
        existingPhotos.removeAll { $0 == name }
        newPhotos.removeAll { $0.name == name }
    }

    /// Re-encodes a picked image as JPEG; nil if it isn't an image.
    nonisolated static func jpeg(from data: Data) -> Data? {
        UIImage(data: data)?.jpegData(compressionQuality: 0.8)
    }

    // MARK: validation

    var validationMessage: String? {
        func check(_ label: String, _ text: String) -> String? {
            switch Typed(text) {
            case .invalid(let s): return Typed.notANumber(label, s)
            case .number(let v) where v < 0: return "Amounts can't be negative."
            default: return nil
            }
        }
        switch Typed(odometer) {
        case .invalid(let s): return Typed.notANumber("Odometer", s)
        case .number(let v) where v <= 0: return "Odometer must be more than zero."
        default: break
        }
        for p in parts where !p.isBlank {
            if let m = check("Qty", p.qty) ?? check("Amount", p.amount) { return m }
            if optionalText(p.name) == nil { return "Every part needs a name." }
        }
        for l in labour where !l.isBlank {
            if let m = check("Amount", l.amount) { return m }
            if optionalText(l.name) == nil { return "Every labour line needs a name." }
        }
        if let m = check("GST", gst) ?? check("Total", totalText) { return m }
        if resetsNeedOdometer, !(original != nil && resetFields == initialResetFields) { return Self.odometerForResets }
        return nil
    }

    private static let odometerForResets = "Enter the odometer: a part resets a maintenance item."

    private var resetsNeedOdometer: Bool {
        Typed(odometer) == .empty && parts.contains { !$0.isBlank && !$0.resets.isEmpty }
    }

    /// Non-blocking: an old entry, unchanged in odometer and resets, that resets an item without an odometer.
    var warningMessage: String? {
        guard validationMessage == nil, resetsNeedOdometer else { return nil }
        return Self.odometerForResets
    }

    // MARK: save

    func build() -> ServiceVisit? {
        guard validationMessage == nil else { return nil }
        let order = resetChoices
        let builtParts = parts.filter { !$0.isBlank }.map { p in
            Part(code: p.code.trimmingCharacters(in: .whitespaces), name: optionalText(p.name) ?? "",
                 qty: Typed(p.qty).value ?? 1, unit: p.unit, amount: Typed(p.amount).value ?? 0,
                 resets: p.resets.sorted { (order.firstIndex(of: $0) ?? .max, $0) < (order.firstIndex(of: $1) ?? .max, $1) })
        }
        let builtLabour = labour.filter { !$0.isBlank }.map {
            Labour(code: $0.code.trimmingCharacters(in: .whitespaces), name: optionalText($0.name) ?? "",
                   amount: Typed($0.amount).value ?? 0)
        }
        // A stored parts_total (it can differ from the line sum, e.g. discounts) is kept while the parts' sum is unchanged.
        let sum = round2(builtParts.map(\.amount).reduce(0, +))
        var partsTotal: Double? = builtParts.isEmpty ? nil : sum
        if let o = original, round2(o.parts.map(\.amount).reduce(0, +)) == sum { partsTotal = o.partsTotal }
        return ServiceVisit(id: id, enteredAt: original?.enteredAt ?? istTimestamp(), date: ISTClock.day(date),
                            odometerKm: Typed(odometer).value, kindName: optionalText(kindName),
                            workshop: optionalText(workshop), invoice: optionalText(invoice),
                            parts: builtParts, labour: builtLabour, partsTotal: partsTotal,
                            gst: Typed(gst).value, total: Typed(totalText).value, notes: optionalText(notes),
                            photos: photos)
    }

    /// Writes new photos into `log/services/<id>/`, then the entry. Any failure removes what this save wrote
    /// and sets `saveError`. Photos removed in the form are deleted only after the entry is saved.
    func save(in book: Book?) -> Bool {
        guard photosLoading == 0, let entry = build() else { return false }
        guard let book else {
            saveError = LogText.saveFailed
            return false
        }
        let dir = "\(EntryKind.service.dir)/\(id)"
        var written: [String] = []
        do {
            for p in newPhotos {
                try book.writeAtomic("\(dir)/\(p.name)", p.data)
                written.append("\(dir)/\(p.name)")
            }
            try I20Core.save(entry, in: book)
        } catch {
            for rel in written { try? book.delete(rel) }
            if !written.isEmpty { removeIfEmpty(dir, in: book) }
            saveError = LogText.saveFailed
            return false
        }
        let kept = Set(entry.photos)
        let removed = (original?.photos ?? []).filter { !kept.contains($0) }
        cleanupWarning = nil
        for name in removed where book.exists("\(dir)/\(name)") {
            do { try book.delete("\(dir)/\(name)") } catch { cleanupWarning = Self.photoNotDeleted }
        }
        if !removed.isEmpty { removeIfEmpty(dir, in: book) }
        saveError = nil
        return true
    }

    private func removeIfEmpty(_ dir: String, in book: Book) {
        if book.exists(dir), (try? book.list(dir))?.isEmpty == true { try? book.delete(dir) }
    }
}

// MARK: view

struct ServiceForm: View {
    @StateObject private var model: ServiceFormModel
    let book: Book?
    /// Called after a successful save with a non-blocking warning, if any.
    let onSaved: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picked: [PhotosPickerItem] = []

    init(model: @autoclosure @escaping () -> ServiceFormModel, book: Book?, onSaved: @escaping (String?) -> Void) {
        _model = StateObject(wrappedValue: model())
        self.book = book
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Visit") {
                    DatePicker("Date", selection: $model.date, displayedComponents: .date)
                        .environment(\.timeZone, ISTClock.zone)
                    TextField("Odometer km", text: $model.odometer).keyboardType(.numberPad)
                    TextField("Kind (e.g. Free service, Paid service)", text: $model.kindName)
                    TextField("Workshop", text: $model.workshop)
                    TextField("Invoice number", text: $model.invoice)
                }
                Section {
                    ForEach($model.parts) { $row in partRow($row) }
                        .onDelete { model.parts.remove(atOffsets: $0) }
                    Button("Add part", systemImage: "plus") { model.addPart() }
                    if let note = model.resetNote, model.resetChoices.isEmpty {
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Parts")
                } footer: {
                    Text("Parts ₹\(model.partsTotalText)")
                }
                Section {
                    ForEach($model.labour) { $row in
                        VStack {
                            TextField("Name", text: $row.name)
                            HStack {
                                TextField("Code", text: $row.code)
                                TextField("Amount ₹", text: $row.amount).keyboardType(.decimalPad)
                            }
                        }
                    }
                    .onDelete { model.labour.remove(atOffsets: $0) }
                    Button("Add labour", systemImage: "plus") { model.addLabour() }
                } header: {
                    Text("Labour")
                } footer: {
                    Text("Labour ₹\(model.labourTotalText)")
                }
                Section("Totals") {
                    LabeledContent("GST ₹") { TextField("0", text: $model.gst).keyboardType(.decimalPad) }
                    LabeledContent("Total ₹") { TextField("0", text: $model.totalText).keyboardType(.decimalPad) }
                }
                Section("Notes") {
                    TextField("Notes", text: $model.notes, axis: .vertical)
                }
                Section("Photos") {
                    ForEach(model.photos, id: \.self) { name in
                        HStack {
                            if let data = model.newPhotoData(name), let img = UIImage(data: data) {
                                Image(uiImage: img).resizable().scaledToFill().frame(width: 44, height: 44).clipped()
                            } else {
                                Image(systemName: "photo").frame(width: 44, height: 44)
                            }
                            Text(name).font(.footnote)
                        }
                    }
                    .onDelete { idx in idx.map { model.photos[$0] }.forEach(model.removePhoto) }
                    PhotosPicker(selection: $picked, matching: .images) {
                        Label("Add photos", systemImage: "camera")
                    }
                    if model.photosLoading > 0 {
                        HStack { ProgressView(); Text("Loading photos\u{2026}").font(.footnote) }
                    }
                    if let e = model.photoError {
                        Text(e).font(.footnote).foregroundStyle(.red)
                    }
                }
                if let m = model.validationMessage {
                    Section { Text(m).foregroundStyle(.red) }
                } else if let w = model.warningMessage {
                    Section { Text(w).foregroundStyle(.orange) }
                }
            }
            .navigationTitle(model.isEditing ? "Edit service" : "Service")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if model.save(in: book) {
                            onSaved(model.cleanupWarning)
                            dismiss()
                        }
                    }
                    .disabled(!model.canSave)
                }
            }
            .alert(model.saveError ?? "", isPresented: saveErrorShown) {
                Button("OK", role: .cancel) {}
            }
            .onChange(of: picked) { _, items in
                guard !items.isEmpty else { return }
                picked = []
                model.photoError = nil
                for _ in items { model.photoLoadStarted() }
                Task {
                    for item in items {
                        let data = try? await item.loadTransferable(type: Data.self)
                        model.photoLoaded(data)
                    }
                }
            }
            .task {
                let book = self.book
                let items = await Task.detached { MaintenanceItems.latest(in: book) }.value
                model.setMaintenance(names: items.names, note: items.note)
            }
        }
    }

    private var saveErrorShown: Binding<Bool> {
        Binding(get: { model.saveError != nil }, set: { if !$0 { model.saveError = nil } })
    }

    private func partRow(_ row: Binding<PartRow>) -> some View {
        VStack(alignment: .leading) {
            TextField("Name", text: row.name)
            HStack {
                TextField("Code", text: row.code)
                TextField("Qty", text: row.qty).keyboardType(.decimalPad).frame(maxWidth: 60)
                TextField("Amount ₹", text: row.amount).keyboardType(.decimalPad)
            }
            if !model.resetChoices.isEmpty {
                Menu {
                    ForEach(model.resetChoices, id: \.self) { name in
                        Toggle(name, isOn: Binding(
                            get: { row.wrappedValue.resets.contains(name) },
                            set: { on in
                                if on { row.wrappedValue.resets.insert(name) } else { row.wrappedValue.resets.remove(name) }
                            }))
                    }
                } label: {
                    let r = model.resetChoices.filter { row.wrappedValue.resets.contains($0) }
                    Label(r.isEmpty ? "Resets: none" : "Resets: " + r.joined(separator: ", "),
                          systemImage: "arrow.counterclockwise")
                        .font(.footnote)
                }
            }
        }
    }
}
