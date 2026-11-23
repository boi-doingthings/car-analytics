import SwiftUI
import I20Core

enum LogText {
    static let saveFailed = "Couldn't save to iCloud Drive (i20_book). Nothing was saved."
    static let deleteFailed = "Couldn't delete from iCloud Drive (i20_book)."
    static let photosNotDeleted = "The entry was deleted, but its photos couldn't be removed from iCloud Drive (i20_book)."
    static let loadFailed = "Can't read the log in iCloud Drive (i20_book)."
    static let readOnly = "This archive is read-only. Enable archive changes in Settings before adding, editing or deleting records."
    static let archiveChanged = "The selected logbook or entry changed. Reload it before editing or deleting."
    static let stillDownloading = "Some entries are still downloading from iCloud \u{2014} pull to refresh."
}

/// Entry dates and times are Asia/Kolkata, whatever the phone's time zone.
enum ISTClock {
    static let zone = TimeZone(identifier: "Asia/Kolkata")!

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = format
        return f
    }

    static func day(_ d: Date) -> String { formatter("yyyy-MM-dd").string(from: d) }
    static func time(_ d: Date) -> String { formatter("HH:mm").string(from: d) }

    /// `YYYY-MM-DD` (+ optional `HH:MM`) in IST; midnight when the time is unknown.
    static func date(day: String, time: String? = nil) -> Date? {
        if let time, let d = formatter("yyyy-MM-dd HH:mm").date(from: "\(day) \(time)") { return d }
        return formatter("yyyy-MM-dd").date(from: day)
    }
}

/// What a number field holds.
enum Typed: Equatable {
    case empty
    case number(Double)
    case invalid(String)

    init(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { self = .empty } else if let v = RefuelMath.parse(t) { self = .number(v) } else { self = .invalid(t) }
    }

    var value: Double? { if case .number(let v) = self { v } else { nil } }

    static func notANumber(_ label: String, _ text: String) -> String { "\(label) \u{201C}\(text)\u{201D} isn't a number." }
}

/// A stored number as typed text: shortest form, no trailing `.0`.
func plainNumber(_ v: Double?) -> String {
    guard let v else { return "" }
    if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
    return String(v)
}

/// Rounded to 2 decimals, trailing zeros dropped.
func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

/// Trimmed text, nil when empty.
func optionalText(_ s: String) -> String? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

// MARK: list model

enum LogFilter: String, CaseIterable, Identifiable {
    case all = "All", fuel = "Fuel", service = "Service", other = "Other"
    var id: String { rawValue }
}

enum LogItem: Identifiable, Equatable {
    case refuel(Refuel)
    case service(ServiceVisit)
    case maintenance(Maintenance)

    var kind: EntryKind {
        switch self { case .refuel: .refuel; case .service: .service; case .maintenance: .maintenance }
    }

    var entryID: String {
        switch self { case .refuel(let r): r.id; case .service(let s): s.id; case .maintenance(let m): m.id }
    }

    var id: String { "\(kind.dir)/\(entryID)" }
    var path: String { "\(kind.dir)/\(entryID).json" }

    var date: String {
        switch self { case .refuel(let r): r.date; case .service(let s): s.date; case .maintenance(let m): m.date }
    }

    var enteredAt: String {
        switch self {
        case .refuel(let r): r.enteredAt; case .service(let s): s.enteredAt; case .maintenance(let m): m.enteredAt
        }
    }

    /// Date, then time for refuels: newest-first ordering.
    var sortKey: String {
        if case .refuel(let r) = self { return r.date + (r.time ?? "") }
        return date
    }

    var filter: LogFilter {
        switch self { case .refuel: .fuel; case .service: .service; case .maintenance: .other }
    }
}

/// The owner's log entries, read from the book.
@MainActor
final class LogStore: ObservableObject {
    @Published private(set) var items: [LogItem] = []
    @Published private(set) var loadError: String?
    @Published private(set) var skipped = 0
    @Published var actionError: String?

    static let downloadTimeout: TimeInterval = 30
    private let placeholderTimeout: TimeInterval
    private var loadRevision = 0
    private(set) var archiveRoot: URL?

    init(downloadTimeout: TimeInterval = LogStore.downloadTimeout) {
        self.placeholderTimeout = downloadTimeout
    }

    var refuels: [Refuel] { items.compactMap { if case .refuel(let r) = $0 { r } else { nil } } }

    func visible(_ filter: LogFilter) -> [LogItem] {
        filter == .all ? items : items.filter { $0.filter == filter }
    }

    func load(from book: Book?) async {
        loadRevision += 1
        let revision = loadRevision
        let root = book?.root
        if archiveRoot != root {
            // Retain cached records on a same-archive download failure only, never across archives.
            items = []
            skipped = 0
            loadError = nil
            actionError = nil
            archiveRoot = root
        }
        guard let book else {
            items = []
            skipped = 0
            loadError = LogText.loadFailed
            return
        }
        do {
            let r = try await loadAll(Refuel.self, from: book, timeout: placeholderTimeout)
            let s = try await loadAll(ServiceVisit.self, from: book, timeout: placeholderTimeout)
            let m = try await loadAll(Maintenance.self, from: book, timeout: placeholderTimeout)
            guard revision == loadRevision, archiveRoot == root, !Task.isCancelled else { return }
            let all = r.entries.map(LogItem.refuel) + s.entries.map(LogItem.service) + m.entries.map(LogItem.maintenance)
            items = all.sorted { ($0.sortKey, $0.enteredAt, $0.id) > ($1.sortKey, $1.enteredAt, $1.id) }
            skipped = r.skipped.count + s.skipped.count + m.skipped.count
            loadError = nil
        } catch {
            guard revision == loadRevision, archiveRoot == root, !Task.isCancelled else { return }
            switch error {
            case BookError.notDownloaded, BookError.downloadFailed:
                loadError = LogText.stillDownloading
            case is CancellationError:
                return
            default:
                items = []
                skipped = 0
                loadError = LogText.loadFailed
            }
        }
    }

    /// A loaded record must still belong to the selected archive and retain its loaded contents.
    /// In particular, matching UUIDs in a different archive do not grant permission to overwrite it.
    func editingBook(for item: LogItem, in book: Book?) -> Book? {
        guard let book, book.canWrite, archiveRoot == book.root, items.contains(item) else { return nil }
        return book
    }

    /// Deletes the entry file and, for a service, its photo folder. False (with `actionError`) if the entry
    /// couldn't be deleted.
    @discardableResult
    func delete(_ item: LogItem, in book: Book?) -> Bool {
        guard let book else {
            actionError = LogText.deleteFailed
            return false
        }
        guard book.canWrite else {
            actionError = LogText.readOnly
            return false
        }
        guard editingBook(for: item, in: book) != nil else {
            actionError = LogText.archiveChanged
            return false
        }
        do { try book.delete(item.path) } catch {
            actionError = LogText.deleteFailed
            return false
        }
        if case .service(let s) = item {
            let dir = "\(EntryKind.service.dir)/\(s.id)"
            if book.exists(dir) {
                do { try book.delete(dir) } catch { actionError = LogText.photosNotDeleted }
            }
        }
        items.removeAll { $0.id == item.id }
        return true
    }

    /// Rebuilds the analytics after a log edit; waits for a running sync first so the edit isn't missed.
    static func rebuildAfterSave(_ sync: SyncCoordinator) async {
        if sync.state.running { await sync.task?.value }
        sync.rebuild()
        await sync.task?.value
    }
}

// MARK: views

struct LogListView: View {
    @EnvironmentObject var folder: FolderAccess
    @EnvironmentObject var sync: SyncCoordinator
    @StateObject private var store = LogStore()
    @State private var filter: LogFilter = .all
    @State private var sheet: LogSheet?
    @State private var pendingDelete: LogItem?
    @State private var presentationArchiveRoot: URL?
    @State private var deletionArchiveRoot: URL?
    @State private var showAccessSettings = false

    enum LogSheet: Identifiable {
        case newRefuel, newService, newOther
        case edit(LogItem)
        case inspect(LogItem)

        var id: String {
            switch self {
            case .newRefuel: "new-refuel"; case .newService: "new-service"; case .newOther: "new-other"
            case .edit(let i): i.id
            case .inspect(let i): "inspect-\(i.id)"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !folder.writesAllowed {
                    HStack {
                        Label("Read-only", systemImage: "lock").font(.subheadline)
                        Spacer(minLength: 0)
                        Button("Manage access") { showAccessSettings = true }
                            .font(.subheadline)
                            .accessibilityIdentifier("logManageArchiveAccess")
                    }
                    .accessibilityIdentifier("logReadOnlyStatus")
                }
                Picker("Show", selection: $filter) {
                    ForEach(LogFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("logFilter")
                if let e = store.loadError {
                    Text(e).foregroundStyle(.red)
                }
                ForEach(store.visible(filter)) { item in
                    Button { present(folder.writesAllowed ? .edit(item) : .inspect(item)) } label: { LogRow(item: item) }
                        .foregroundStyle(.primary)
                        .swipeActions {
                            if folder.writesAllowed {
                                Button(role: .destructive) {
                                    deletionArchiveRoot = folder.book?.root
                                    pendingDelete = item
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                }
                if store.skipped > 0 {
                    Text("\(store.skipped) entr\(store.skipped == 1 ? "y" : "ies") couldn't be read (made by a newer app or damaged).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Log")
            .toolbar {
                Menu {
                    Button { present(.newRefuel) } label: { Label("Refuel", systemImage: "fuelpump") }
                    Button { present(.newService) } label: { Label("Service", systemImage: "wrench.and.screwdriver") }
                    Button { present(.newOther) } label: { Label("Other", systemImage: "list.bullet") }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("addMenu")
                .disabled(!folder.writesAllowed)
            }
            .safeAreaInset(edge: .bottom) {
                Button { present(.newRefuel) } label: {
                    Label("Refuel", systemImage: "fuelpump.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
                .accessibilityIdentifier("refuelButton")
                .disabled(!folder.writesAllowed)
            }
            .refreshable { await store.load(from: folder.book) }
            .task(id: folder.book?.root) { await store.load(from: folder.book) }
            .onChange(of: folder.book?.root) { _, _ in
                sheet = nil
                pendingDelete = nil
                presentationArchiveRoot = nil
                deletionArchiveRoot = nil
            }
            .onChange(of: folder.writesAllowed) { _, allowed in
                if !allowed {
                    if let current = sheet {
                        switch current { case .inspect: break; default: sheet = nil }
                    }
                    pendingDelete = nil
                    deletionArchiveRoot = nil
                }
            }
            .sheet(item: $sheet) { form(for: $0) }
            .sheet(isPresented: $showAccessSettings) {
                SettingsView().presentationDragIndicator(.visible)
            }
            .confirmationDialog("Delete this entry?", isPresented: deleteDialogShown, titleVisibility: .visible,
                                presenting: pendingDelete) { item in
                Button("Delete", role: .destructive) {
                    guard folder.writesAllowed else {
                        store.actionError = LogText.readOnly
                        return
                    }
                    guard deletionArchiveRoot == folder.book?.root else {
                        store.actionError = LogText.archiveChanged
                        return
                    }
                    if store.delete(item, in: folder.book) { Task { await LogStore.rebuildAfterSave(sync) } }
                }
            } message: { item in
                if case .service = item {
                    Text("The entry and its photos are removed from i20_book.")
                } else {
                    Text("The entry is removed from i20_book.")
                }
            }
            .alert(store.actionError ?? "", isPresented: actionErrorShown) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private var deleteDialogShown: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var actionErrorShown: Binding<Bool> {
        Binding(get: { store.actionError != nil }, set: { if !$0 { store.actionError = nil } })
    }

    private func present(_ value: LogSheet) {
        switch value {
        case .inspect: break
        default:
            guard folder.writesAllowed else { store.actionError = LogText.readOnly; return }
        }
        if case .edit(let item) = value, store.editingBook(for: item, in: folder.book) == nil {
            store.actionError = LogText.archiveChanged
            return
        }
        presentationArchiveRoot = folder.book?.root
        sheet = value
    }

    private func saved() {
        Task {
            await store.load(from: folder.book)
            await LogStore.rebuildAfterSave(sync)
        }
    }

    private func savedService(_ warning: String?) {
        if let warning { store.actionError = warning }
        saved()
    }

    @ViewBuilder
    private func form(for sheet: LogSheet) -> some View {
        let book = folder.book?.root == presentationArchiveRoot ? folder.book : nil
        switch sheet {
        case .inspect(let item):
            LogReadOnlyDetailView(item: item)
        case .newRefuel:
            RefuelForm(model: RefuelFormModel(past: store.refuels), book: book, onSaved: saved)
        case .newService:
            ServiceForm(model: ServiceFormModel(resetChoices: []), book: book, onSaved: savedService)
        case .newOther:
            MaintenanceForm(model: MaintenanceFormModel(), book: book, onSaved: saved)
        case .edit(.refuel(let r)):
            RefuelForm(model: RefuelFormModel(editing: r, past: store.refuels), book: store.editingBook(for: .refuel(r), in: book), onSaved: saved)
        case .edit(.service(let s)):
            ServiceForm(model: ServiceFormModel(editing: s, resetChoices: []), book: store.editingBook(for: .service(s), in: book), onSaved: savedService)
        case .edit(.maintenance(let m)):
            MaintenanceForm(model: MaintenanceFormModel(editing: m), book: store.editingBook(for: .maintenance(m), in: book), onSaved: saved)
        }
    }
}

struct LogRow: View {
    let item: LogItem

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let amount { Text("₹\(plainNumber(round2(amount)))").monospacedDigit() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("logRow")
    }

    private var icon: String {
        switch item { case .refuel: "fuelpump"; case .service: "wrench.and.screwdriver"; case .maintenance: "list.bullet" }
    }

    private var title: String {
        switch item {
        case .refuel(let r):
            let name = r.station.isEmpty ? "Refuel" : r.station
            return r.missed ? "\(name) (missed fill)" : name
        case .service(let s): return s.kindName ?? s.workshop ?? "Service"
        case .maintenance(let m): return m.category.label
        }
    }

    private var subtitle: String {
        var parts = [item.date]
        switch item {
        case .refuel(let r):
            if let t = r.time { parts[0] += " \(t)" }
            if let l = r.litres { parts.append("\(plainNumber(round2(l))) L") }
            if let o = r.odometerKm { parts.append("\(plainNumber(o)) km") }
        case .service(let s):
            if let o = s.odometerKm { parts.append("\(plainNumber(o)) km") }
            if let w = s.workshop, s.kindName != nil { parts.append(w) }
        case .maintenance(let m):
            if let n = m.note { parts.append(n) }
        }
        return parts.joined(separator: " · ")
    }

    private var amount: Double? {
        switch item { case .refuel(let r): r.amount; case .service(let s): s.total; case .maintenance(let m): m.cost }
    }
}

/// Browsing a record never instantiates a form or exposes a save/delete action.
private struct LogReadOnlyDetailView: View {
    let item: LogItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Read-only archive", systemImage: "lock")
                    LabeledContent("Date", value: item.date)
                } footer: {
                    Text("Browse this record without changing it. Archive changes can be enabled in Settings.")
                }
                switch item {
                case .refuel(let record):
                    Section("Refuel") {
                        field("Station", record.station)
                        field("Company", record.company)
                        field("Time", record.time)
                        amount("Payment", record.amount, suffix: "INR")
                        amount("Litres", record.litres, suffix: "L")
                        amount("Rate", record.rate, suffix: "INR/L")
                        amount("Odometer", record.odometerKm, suffix: "km")
                        LabeledContent("Tank", value: record.fullTank.map { $0 ? "Full" : "Partial" } ?? "Not recorded")
                        LabeledContent("Missed fill", value: record.missed ? "Yes" : "No")
                        field("Note", record.note)
                    }
                case .service(let record):
                    Section("Service") {
                        field("Workshop", record.workshop)
                        field("Kind", record.kindName)
                        field("Invoice", record.invoice)
                        amount("Odometer", record.odometerKm, suffix: "km")
                        amount("Parts", record.partsTotal, suffix: "INR")
                        amount("Tax", record.gst, suffix: "INR")
                        amount("Total", record.total, suffix: "INR")
                        field("Notes", record.notes)
                    }
                    if !record.parts.isEmpty {
                        Section("Parts") {
                            ForEach(Array(record.parts.enumerated()), id: \.offset) { _, part in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(part.name)
                                    Text("\(plainNumber(part.amount)) INR").font(.subheadline).foregroundStyle(.secondary)
                                    if !part.resets.isEmpty { Text("Resets: \(part.resets.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                    if !record.labour.isEmpty {
                        Section("Labour") {
                            ForEach(Array(record.labour.enumerated()), id: \.offset) { _, labour in
                                LabeledContent(labour.name, value: "\(plainNumber(labour.amount)) INR")
                            }
                        }
                    }
                    if !record.photos.isEmpty {
                        Section {
                            LabeledContent("Attached photos", value: "\(record.photos.count)")
                        } footer: {
                            Text("Original attachments remain in the archive.")
                        }
                    }
                case .maintenance(let record):
                    Section("Expense or maintenance") {
                        LabeledContent("Category", value: record.category.label)
                        amount("Cost", record.cost, suffix: "INR")
                        amount("Odometer", record.odometerKm, suffix: "km")
                        field("Note", record.note)
                        field("Reminder", record.reminder)
                    }
                }
            }
            .navigationTitle("Record details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .accessibilityIdentifier("readOnlyLogDetail")
        }
    }

    @ViewBuilder private func field(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty { LabeledContent(title, value: value) }
    }

    private func amount(_ title: String, _ value: Double?, suffix: String) -> some View {
        LabeledContent(title, value: value.map { "\(plainNumber($0)) \(suffix)" } ?? "Not recorded")
    }
}
