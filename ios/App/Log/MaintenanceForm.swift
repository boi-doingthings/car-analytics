import SwiftUI
import I20Core

/// Other maintenance / car costs: date, odometer, category, cost, note, optional reminder date.
@MainActor
final class MaintenanceFormModel: ObservableObject {
    let id: String
    let isEditing: Bool
    private let original: Maintenance?

    @Published var date: Date
    @Published var odometer = ""
    @Published var category: MaintenanceCategory = .other
    @Published var cost = ""
    @Published var note = ""
    @Published var hasReminder = false
    @Published var reminder: Date
    @Published var saveError: String?

    init(now: Date = Date()) {
        id = newEntryID()
        isEditing = false
        original = nil
        date = now
        reminder = now
    }

    init(editing m: Maintenance) {
        id = m.id
        isEditing = true
        original = m
        let day = ISTClock.date(day: m.date) ?? Date()
        date = day
        odometer = plainNumber(m.odometerKm)
        category = m.category
        cost = plainNumber(m.cost)
        note = m.note ?? ""
        hasReminder = m.reminder != nil
        reminder = m.reminder.flatMap { ISTClock.date(day: $0) } ?? day
    }

    var validationMessage: String? {
        switch Typed(cost) {
        case .empty: return "Enter the cost."
        case .invalid(let s): return Typed.notANumber("Cost", s)
        case .number(let v) where v < 0: return "Cost can't be negative."
        default: break
        }
        switch Typed(odometer) {
        case .invalid(let s): return Typed.notANumber("Odometer", s)
        case .number(let v) where v <= 0: return "Odometer must be more than zero."
        default: return nil
        }
    }

    func build() -> Maintenance? {
        guard validationMessage == nil, let c = Typed(cost).value else { return nil }
        return Maintenance(id: id, enteredAt: original?.enteredAt ?? istTimestamp(), date: ISTClock.day(date),
                           odometerKm: Typed(odometer).value, category: category, cost: c, note: optionalText(note),
                           reminder: hasReminder ? ISTClock.day(reminder) : nil)
    }

    /// Writes `log/maintenance/<id>.json`; on failure sets `saveError` and writes nothing.
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

extension MaintenanceCategory {
    var label: String {
        switch self {
        case .puc: "PUC"
        default: rawValue.capitalized
        }
    }
}

struct MaintenanceForm: View {
    @StateObject private var model: MaintenanceFormModel
    let book: Book?
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(model: @autoclosure @escaping () -> MaintenanceFormModel, book: Book?, onSaved: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model())
        self.book = book
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $model.date, displayedComponents: .date)
                    TextField("Odometer km (optional)", text: $model.odometer).keyboardType(.numberPad)
                    Picker("Category", selection: $model.category) {
                        ForEach(MaintenanceCategory.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    TextField("Cost ₹", text: $model.cost).keyboardType(.decimalPad)
                    TextField("Note", text: $model.note, axis: .vertical)
                }
                Section {
                    Toggle("Remind me", isOn: $model.hasReminder)
                    if model.hasReminder {
                        DatePicker("On", selection: $model.reminder, displayedComponents: .date)
                    }
                }
                if let m = model.validationMessage {
                    Section { Text(m).foregroundStyle(.red) }
                }
            }
            .environment(\.timeZone, ISTClock.zone)
            .navigationTitle(model.isEditing ? "Edit cost" : "Other cost")
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
                }
            }
            .alert(model.saveError ?? "", isPresented: saveErrorShown) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private var saveErrorShown: Binding<Bool> {
        Binding(get: { model.saveError != nil }, set: { if !$0 { model.saveError = nil } })
    }
}
