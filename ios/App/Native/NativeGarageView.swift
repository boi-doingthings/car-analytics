import SwiftUI
import I20Core

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
                    recordsCard
                    if let error = store.loadError {
                        NativeNotice(symbol: "exclamationmark.triangle", title: "Logbook unavailable", message: error)
                    }
                    if store.skipped > 0 {
                        NativeNotice(symbol: "doc.badge.ellipsis", title: "Records need review", message: "\(store.skipped) records couldn’t be read. Open Settings for the latest sync issues.")
                    }
                    maintenanceCard
                    serviceHistoryCard
                    cashCard
                    runningCostCard
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
                Image(systemName: symbol).font(.title3.weight(.semibold))
                    .foregroundStyle(NativeTheme.iconTint(for: symbol))
                    .frame(width: 36, height: 32)
                    .background(NativeTheme.iconTint(for: symbol).opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                Text(title).font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .padding(8)
            .background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(NativeTheme.border, lineWidth: 0.5))
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

    private var recordsCard: some View {
        NativeCard(title: "Records & service", symbol: "book.closed") {
            Button { sheet = .logbook } label: {
                Label("Open logbook", systemImage: "book.pages").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(NativeTheme.action).controlSize(.large)
            .accessibilityIdentifier("openLogbook")
            NavigationLink {
                NativeServiceHistoryView(items: store.items)
            } label: {
                Label("Service history & invoices", systemImage: "wrench.and.screwdriver")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.accessibilityIdentifier("openServiceHistory")
            Divider()
            NavigationLink {
                NativeMaintenancePlanView(snapshot: snapshot)
            } label: {
                Label("Full maintenance plan & reminders", systemImage: "calendar.badge.clock")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.accessibilityIdentifier("openMaintenancePlan")
            Text("Browse every recorded visit and its original attachments. Fuel history, model diagnostics and scenarios now live together in Lab.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var services: [I20Core.ServiceVisit] {
        store.items.compactMap { if case .service(let visit) = $0 { return visit }; return nil }
    }

    private var serviceHistoryCard: some View {
        NativeCard(title: "Recent workshop visits", symbol: "clock.arrow.circlepath") {
            if services.isEmpty {
                Text("No service visits have been recorded. Add the work that was actually done to preserve parts, labour, odometer and invoice history.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(services.prefix(3)) { service in
                    NavigationLink {
                        LogReadOnlyDetailView(item: .service(service), archiveRoot: folder.book?.root)
                    } label: {
                        NativeServiceRow(service: service).foregroundStyle(.primary)
                    }.buttonStyle(.plain)
                }
                NavigationLink("View all \(services.count) visits") { NativeServiceHistoryView(items: store.items) }
                    .frame(minHeight: 44)
            }
        }
    }

    private var runningCostCard: some View {
        NativeCard(title: "Running cost per kilometre", symbol: "indianrupeesign.circle") {
            if let cost = snapshot?.overview.runningCost {
                let rates = GarageCostEvidence(cost: cost, fuel: snapshot?.fuel?.totals).rates
                NativeMetric(title: "Combined recorded / modelled rate", value: rates.total.map { "₹\(NativeFormat.number($0, digits: 2))" } ?? "Unavailable", unit: "/km")
                NativeRunningCostChart(rates: rates)
                costRow("Fuel · model estimate", value: rates.fuel)
                costRow("Logged service payments", value: rates.service)
                costRow("Logged other payments", value: rates.other)
                Text("Fuel uses modelled consumption over archived trips. Service and other payments are divided by the reported odometer (\(NativeFormat.number(cost.km)) km). These different coverage windows are not a complete ownership-cost accounting.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Running-cost rates appear when odometer and usable fuel/history inputs are available. Missing components stay unavailable.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func costRow(_ title: String, value: Double?) -> some View {
        LabeledContent(title, value: value.map { "₹\(NativeFormat.number($0, digits: 2))/km" } ?? "Unavailable")
            .font(.subheadline)
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
