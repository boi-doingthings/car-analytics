import SwiftUI
import I20Core

/// Refuel form logic: any two of litres / amount / rate (the third shown live, never stored: the fuel model
/// imputes it), odometer typed by the owner
/// (required unless the fill was missed), full tank on by default, station from the owner's own past fills.
@MainActor
final class RefuelFormModel: ObservableObject {
    enum Field: Equatable { case litres, amount, rate }

    let id: String
    let isEditing: Bool
    private let original: Refuel?
    private let initialWhen: Date
    /// Fuel and odometer fields as loaded, so checks on old (migrated) entries block only after a change.
    private var initialFields: [String] = []
    /// The owner's other fills (this entry excluded).
    let past: [Refuel]

    @Published var when: Date
    @Published var litres = ""
    @Published var amount = ""
    @Published var rate = ""
    @Published var odometer = ""
    /// nil = not recorded (only offered when editing an entry that has no value).
    @Published var fullTank: Bool? = true
    @Published var missed = false {
        didSet { missedChanged(from: oldValue) }
    }
    @Published var station = ""
    @Published var company = ""
    @Published var note = ""
    @Published private(set) var lat: Double?
    @Published private(set) var lon: Double?
    @Published var saveError: String?

    init(past: [Refuel], now: Date = Date()) {
        id = newEntryID()
        isEditing = false
        original = nil
        self.past = past
        when = now
        initialWhen = now
    }

    init(editing r: Refuel, past: [Refuel]) {
        id = r.id
        isEditing = true
        original = r
        self.past = past.filter { $0.id != r.id }
        let w = ISTClock.date(day: r.date, time: r.time) ?? Date()
        when = w
        initialWhen = w
        litres = plainNumber(r.litres)
        amount = plainNumber(r.amount)
        rate = plainNumber(r.rate)
        odometer = plainNumber(r.odometerKm)
        fullTank = r.fullTank
        missed = r.missed
        station = r.station
        company = r.company ?? ""
        note = r.note ?? ""
        lat = r.lat
        lon = r.lon
        initialFields = fuelFields
    }

    /// Set once the owner picks Full tank themselves, so toggling "missed" no longer changes it.
    private var tankChosen = false

    /// A missed fill's tank state is unknown: new entries switch to Not recorded (and back when switched off)
    /// unless the owner chose explicitly.
    private func missedChanged(from old: Bool) {
        guard !isEditing, !tankChosen, missed != old else { return }
        fullTank = missed ? nil : true
    }

    /// Call when the owner picks a tank state.
    func chooseTank(_ value: Bool?) {
        tankChosen = true
        fullTank = value
    }

    private var fuelFields: [String] { [litres, amount, rate, odometer, missed ? "missed" : ""] }

    /// True while every fuel and odometer field is as loaded from an existing entry.
    private var untouchedOld: Bool { original != nil && fuelFields == initialFields }

    /// Full / Partial / Not recorded: offered when editing an entry whose full_tank is unknown, and for a new missed fill.
    var offersUnknownTank: Bool { isEditing ? original?.fullTank == nil : missed }

    /// The phone's location when the form opened: the pump's coordinates. Ignored when editing (the phone
    /// is no longer at the pump).
    func setLocation(lat: Double, lon: Double) {
        guard !isEditing else { return }
        self.lat = lat
        self.lon = lon
    }

    // MARK: derived values

    private var typed: (litres: Typed, amount: Typed, rate: Typed) { (Typed(litres), Typed(amount), Typed(rate)) }

    /// The field left empty when exactly two valid values are typed, with its value.
    private var derived: (field: Field, value: Double)? {
        let t = typed
        let vals = [t.litres.value, t.amount.value, t.rate.value]
        guard vals.compactMap({ $0 }).count == 2,
              [t.litres, t.amount, t.rate].filter({ $0 == .empty }).count == 1,
              case .success(let c) = RefuelMath.complete(litres: vals[0], amount: vals[1], rate: vals[2])
        else { return nil }
        if t.litres == .empty { return (.litres, round2(c.litres)) }
        if t.amount == .empty { return (.amount, round2(c.amount)) }
        return (.rate, round2(c.rate))
    }

    var derivedField: Field? { derived?.field }
    var derivedText: String? { derived.map { plainNumber($0.value) } }

    /// The previous fill's odometer: the latest other fill before this one that has a reading.
    var previousOdometer: Double? {
        let key = ISTClock.day(when) + ISTClock.time(when)
        return past.filter { $0.odometerKm != nil && $0.date + ($0.time ?? "") < key }
            .max { ($0.date + ($0.time ?? ""), $0.enteredAt) < ($1.date + ($1.time ?? ""), $1.enteredAt) }?
            .odometerKm
    }

    var odometerWarning: String? {
        guard let km = Typed(odometer).value, km > 0 else { return nil }
        return I20Core.odometerWarning(km, previous: previousOdometer)
    }

    var suggestions: [String] {
        let near = lat.flatMap { la in lon.map { (lat: la, lon: $0) } }
        return Stations.suggest(past: past, near: near, prefix: station)
    }

    /// Picks a past station and fills the company from that station's last fill.
    func chooseStation(_ name: String) {
        station = name
        let last = past.filter { $0.station.trimmingCharacters(in: .whitespacesAndNewlines) == name && $0.company != nil }
            .max { ($0.date + ($0.time ?? ""), $0.enteredAt) < ($1.date + ($1.time ?? ""), $1.enteredAt) }
        if let c = last?.company { company = c }
    }

    // MARK: validation

    private static let nonPositiveText = "Litres, amount and rate must be more than zero."

    /// Problems found in the form: (message, softOnOldEntry). Soft ones (two-of-three, mismatch, missing
    /// odometer) don't block re-saving an old entry whose fuel/odometer fields weren't changed.
    private var problem: (message: String, soft: Bool)? {
        let t = typed
        for (label, v) in [("Litres", t.litres), ("Amount", t.amount), ("Rate", t.rate)] {
            if case .invalid(let s) = v { return (Typed.notANumber(label, s), false) }
        }
        let given = [t.litres.value, t.amount.value, t.rate.value]
        if given.contains(where: { $0 != nil && !($0! > 0) }) { return (Self.nonPositiveText, false) }
        if !missed || given.compactMap({ $0 }).count >= 2, let m = fuelMessage(given) { return (m, true) }
        switch Typed(odometer) {
        case .invalid(let s): return (Typed.notANumber("Odometer", s), false)
        case .empty: return missed ? nil : ("Enter the odometer reading.", true)
        case .number(let v): return v > 0 ? nil : ("Odometer must be more than zero.", false)
        }
    }

    /// Why the entry can't be saved yet, or nil.
    var validationMessage: String? {
        guard let p = problem, !(p.soft && untouchedOld) else { return nil }
        return p.message
    }

    /// A non-blocking note: a soft problem on an old entry the owner hasn't changed.
    var warningMessage: String? {
        guard let p = problem, p.soft, untouchedOld else { return nil }
        return p.message
    }

    private func fuelMessage(_ v: [Double?]) -> String? {
        switch RefuelMath.complete(litres: v[0], amount: v[1], rate: v[2]) {
        case .success: nil
        case .failure(.needTwo): "Enter two of litres, amount and rate."
        case .failure(.nonPositive): Self.nonPositiveText
        case .failure(.inconsistent): "Litres \u{00D7} rate doesn't match the amount."
        }
    }

    // MARK: save

    /// The entry as it will be written, or nil while the form is invalid.
    func build() -> Refuel? {
        guard validationMessage == nil else { return nil }
        let t = typed
        // An entry whose time was never known keeps `time: null` unless the date/time was changed.
        let keepUnknownTime = original != nil && original?.time == nil && when == initialWhen
        return Refuel(id: id, enteredAt: original?.enteredAt ?? istTimestamp(),
                      date: keepUnknownTime ? original!.date : ISTClock.day(when),
                      time: keepUnknownTime ? nil : ISTClock.time(when),
                      litres: t.litres.value, amount: t.amount.value, rate: t.rate.value,
                      odometerKm: Typed(odometer).value, fullTank: fullTank,
                      missed: missed, station: station.trimmingCharacters(in: .whitespacesAndNewlines),
                      company: optionalText(company),
                      lat: (missed && !isEditing) ? nil : lat, lon: (missed && !isEditing) ? nil : lon,
                      note: optionalText(note))
    }

    /// Writes `log/refuels/<id>.json` into the book. On failure sets `saveError`; nothing is written elsewhere.
    func save(in book: Book?) -> Bool {
        guard let entry = build() else { return false }
        guard let book else {
            saveError = LogText.saveFailed
            return false
        }
        do {
            try I20Core.save(entry, in: book)
            saveError = nil
            return true
        } catch {
            saveError = LogText.saveFailed
            return false
        }
    }
}

// MARK: view

struct RefuelForm: View {
    @StateObject private var model: RefuelFormModel
    @StateObject private var location = LocationGrabber()
    let book: Book?
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(model: @autoclosure @escaping () -> RefuelFormModel, book: Book?, onSaved: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model())
        self.book = book
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $model.when, displayedComponents: [.date, .hourAndMinute])
                        .environment(\.timeZone, ISTClock.zone)
                    Toggle("This is a fill I missed", isOn: $model.missed)
                        .accessibilityIdentifier("missed")
                }
                Section {
                    number("Litres", $model.litres, .litres, id: "litres")
                    number("Amount (₹)", $model.amount, .amount, id: "amount")
                    number("Rate (₹/L)", $model.rate, .rate, id: "rate")
                    if model.offersUnknownTank {
                        Picker("Tank", selection: Binding(get: { model.fullTank }, set: { model.chooseTank($0) })) {
                            Text("Full").tag(Bool?.some(true))
                            Text("Partial").tag(Bool?.some(false))
                            Text("Not recorded").tag(Bool?.none)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("fullTank")
                    } else {
                        Toggle("Full tank", isOn: Binding(get: { model.fullTank ?? false }, set: { model.chooseTank($0) }))
                            .accessibilityIdentifier("fullTank")
                    }
                } header: {
                    Text("Fuel")
                } footer: {
                    Text("Any two; the third is worked out.")
                }
                Section("Odometer") {
                    TextField(model.missed ? "Odometer km (optional)" : "Odometer km", text: $model.odometer)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("odometer")
                    if let w = model.odometerWarning {
                        Text(w).font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("odometerWarning")
                    }
                }
                Section("Station") {
                    TextField("Station", text: $model.station)
                        .accessibilityIdentifier("station")
                    let chips = Array(model.suggestions.filter { $0 != model.station }.prefix(8))
                    if !chips.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(chips, id: \.self) { name in
                                    Button(name) { model.chooseStation(name) }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                    TextField("Company", text: $model.company)
                        .accessibilityIdentifier("company")
                }
                Section("Note") {
                    TextField("Note", text: $model.note, axis: .vertical)
                }
                if let m = model.validationMessage {
                    Section {
                        Text(m).foregroundStyle(.red).accessibilityIdentifier("validationMessage")
                    }
                } else if let w = model.warningMessage {
                    Section {
                        Text(w).foregroundStyle(.orange).accessibilityIdentifier("warningMessage")
                    }
                }
            }
            .navigationTitle(model.isEditing ? "Edit refuel" : "Refuel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if model.save(in: book) {
                            onSaved()
                            dismiss()
                        }
                    }
                    .disabled(model.validationMessage != nil)
                    .accessibilityIdentifier("save")
                }
            }
            .alert(model.saveError ?? "", isPresented: saveErrorShown) {
                Button("OK", role: .cancel) {}
            }
            .task {
                guard !model.isEditing, let c = await location.grabOnce() else { return }
                model.setLocation(lat: c.lat, lon: c.lon)
            }
        }
    }

    private var saveErrorShown: Binding<Bool> {
        Binding(get: { model.saveError != nil }, set: { if !$0 { model.saveError = nil } })
    }

    private func number(_ label: String, _ text: Binding<String>, _ field: RefuelFormModel.Field, id: String) -> some View {
        HStack {
            TextField(label, text: text)
                .keyboardType(.decimalPad)
                .accessibilityIdentifier(id)
            if model.derivedField == field, let d = model.derivedText {
                Text("= \(d)").foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityIdentifier("derived")
            }
        }
    }
}
