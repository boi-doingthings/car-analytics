import SwiftUI

struct NativeGarageView: View {
    let snapshot: AnalyticsSnapshot?
    var onSettings: () -> Void = {}
    @EnvironmentObject private var folder: FolderAccess
    @EnvironmentObject private var sync: SyncCoordinator
    @StateObject private var store = LogStore()
    @State private var sheet: GarageSheet?
    @State private var serviceWarning: String?

    private enum GarageSheet: String, Identifiable {
        case refuel, service, expense, logbook
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Keep the history. Understand the cost.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    quickActions
                    cashCard
                    if let error = store.loadError {
                        NativeNotice(symbol: "exclamationmark.triangle", title: "Logbook unavailable", message: error)
                    }
                    if store.skipped > 0 {
                        NativeNotice(symbol: "doc.badge.ellipsis", title: "Records need review", message: "\(store.skipped) records couldn’t be read. Open Settings for the latest sync issues.")
                    }
                    fuelCard
                    maintenanceCard
                    NativeCard(title: "Your logbook", symbol: "book.closed") {
                        Text("Refuels, invoices, services and other expenses stay together in your selected archive.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button { sheet = .logbook } label: {
                            Label("Open logbook", systemImage: "arrow.right").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(NativeTheme.action).controlSize(.large)
                        .accessibilityIdentifier("openLogbook")
                    }
                }.padding(16)
            }
            .background(NativeTheme.background)
            .navigationTitle("Garage")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onSettings) { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings").accessibilityIdentifier("openSettings")
                }
            }
            .refreshable { await store.load(from: folder.book) }
            .task(id: folder.book?.root) { await store.load(from: folder.book) }
            .onChange(of: sync.finishedRuns) { _, _ in Task { await store.load(from: folder.book) } }
            .onChange(of: folder.writesAllowed) { _, allowed in
                if !allowed && sheet != .logbook { sheet = nil }
            }
            .sheet(item: $sheet, onDismiss: { Task { await store.load(from: folder.book) } }) { item in
                switch item {
                case .refuel:
                    RefuelForm(model: RefuelFormModel(past: store.refuels), book: folder.book, onSaved: saved)
                case .service:
                    ServiceForm(model: ServiceFormModel(resetChoices: snapshot?.overview.service.map(\.item) ?? []), book: folder.book) { warning in
                        serviceWarning = warning
                        saved()
                    }
                case .expense:
                    MaintenanceForm(model: MaintenanceFormModel(), book: folder.book, onSaved: saved)
                case .logbook:
                    LogListView().presentationDragIndicator(.visible)
                }
            }
            .alert("Service saved", isPresented: Binding(get: { serviceWarning != nil }, set: { if !$0 { serviceWarning = nil } })) {
                Button("OK", role: .cancel) { serviceWarning = nil }
            } message: { Text(serviceWarning ?? "") }
        }
    }

    private var quickActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { addButtons }
            VStack(spacing: 10) { addButtons }
        }
    }

    @ViewBuilder private var addButtons: some View {
        addButton("Refuel", symbol: "fuelpump.fill", sheet: .refuel)
        addButton("Service", symbol: "wrench.and.screwdriver", sheet: .service)
        addButton("Expense", symbol: "receipt", sheet: .expense)
    }

    private func addButton(_ title: String, symbol: String, sheet value: GarageSheet) -> some View {
        Button {
            guard folder.writesAllowed else { return }
            sheet = value
        } label: {
            VStack(spacing: 9) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .padding(8)
            .background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .disabled(!folder.writesAllowed)
        .opacity(folder.writesAllowed ? 1 : 0.5)
        .accessibilityIdentifier("garageAdd\(title)")
        .accessibilityHint(folder.writesAllowed ? "Add a record to this archive." : "Enable archive changes in Settings to add records.")
    }

    private var cashCard: some View {
        let period = recentItems
        let known = period.compactMap(amount)
        return NativeCard(title: "Cash spend · last 30 days", symbol: "indianrupeesign.circle") {
            NativeMetric(title: "Recorded payments", value: NativeFormat.money(known.isEmpty ? nil : known.reduce(0, +)), caption: "\(period.count) logged records in this period")
            Text("Payments are shown on their recorded payment date. This is cash spend, separate from estimated fuel consumed on trips.")
                .font(.caption).foregroundStyle(.secondary)
            if period.count > known.count {
                Text("\(period.count - known.count) records have no amount and are excluded from the total.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if period.isEmpty { Text("No payments were logged in this period.").font(.subheadline) }
        }
    }

    private var fuelCard: some View {
        NativeCard(title: "Fuel evidence", symbol: "drop") {
            if let totals = snapshot?.fuel?.totals {
                NativeMetric(title: "Full-to-full economy", value: NativeFormat.number(totals.economyKMPL, digits: 1), unit: "km/L", caption: "Observed fill intervals, using the current distance calibration")
                Text("Fill history: \(totals.firstFill ?? "unknown") to \(totals.lastFill ?? "unknown"). Trip fuel and costs elsewhere are model estimates.")
                    .font(.caption).foregroundStyle(.secondary)
                if let missing = totals.missingFills, missing > 0 {
                    Label("\(missing) intervals may have missing fills", systemImage: "exclamationmark.circle")
                        .font(.subheadline).foregroundStyle(NativeTheme.accent)
                }
            } else {
                Text("Add complete full-tank refuels to build an economy history. Estimates appear only when enough usable data is available.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var maintenanceCard: some View {
        NativeCard(title: "Next attention", symbol: "wrench.adjustable") {
            if let snapshot, !snapshot.overview.service.isEmpty || !snapshot.overview.reminders.isEmpty {
                ForEach(snapshot.overview.service.prefix(3)) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.item).font(.subheadline.weight(.semibold))
                        Text("\(NativeFormat.number(item.kmDue)) km · \(item.due ?? "Date unavailable")")
                            .font(.subheadline).monospacedDigit()
                        Text(item.lastDone == nil ? "Schedule estimate; replacement history unconfirmed" : "Schedule estimate from a logged replacement")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(snapshot.overview.reminders.prefix(3).enumerated()), id: \.offset) { _, reminder in
                    VStack(alignment: .leading, spacing: 5) {
                        Label(reminder.note ?? reminder.category?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Maintenance reminder", systemImage: "calendar.badge.clock")
                            .font(.subheadline.weight(.semibold))
                        Text("Reminder: \(reminder.date ?? "Date unavailable")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Verify the service schedule and actual work with your workshop. Distance dates depend on your future usage.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(folder.writesAllowed
                     ? "Maintenance items appear after a vehicle sync. You can log a service or dated reminder at any time."
                     : "Maintenance items appear from archived vehicle records. Enable archive changes in Settings to add a service or reminder.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var recentItems: [LogItem] {
        let calendar = AnalyticsDate.calendar
        let today = calendar.startOfDay(for: Date())
        let from = calendar.date(byAdding: .day, value: -29, to: today)!
        let until = calendar.date(byAdding: .day, value: 1, to: today)!
        return store.items.filter { item in
            guard let date = ISTClock.date(day: item.date) else { return false }
            return date >= from && date < until
        }
    }

    private func amount(_ item: LogItem) -> Double? {
        switch item {
        case .refuel(let entry): entry.amount
        case .service(let entry): entry.total
        case .maintenance(let entry): entry.cost
        }
    }

    private func saved() {
        Task {
            await store.load(from: folder.book)
            await LogStore.rebuildAfterSave(sync)
        }
    }
}
