import SwiftUI
import Charts
import I20Core

/// Read-only service exploration shares the canonical log reader and detail view with the logbook.
struct NativeServiceHistoryView: View {
    let items: [LogItem]
    @EnvironmentObject private var folder: FolderAccess
    @State private var search = ""

    private var services: [ServiceVisit] {
        items.compactMap { if case .service(let record) = $0 { return record }; return nil }
    }
    private var filtered: [ServiceVisit] {
        services.filter { record in
            search.isEmpty || [record.date, record.workshop, record.kindName, record.invoice,
                               record.notes, record.parts.map(\.name).joined(separator: " ")]
                .compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Logged visits", value: String(services.count))
                let amounts = services.compactMap(\.total)
                LabeledContent("Recorded service payments", value: NativeFormat.money(amounts.isEmpty ? nil : amounts.reduce(0, +)))
                Text("Recorded invoices only. Missing amounts are excluded; an unlogged replacement is not assumed to have happened.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !filtered.isEmpty {
                Section("\(filtered.count) visits") {
                    ForEach(filtered) { service in
                        NavigationLink {
                            LogReadOnlyDetailView(item: .service(service), archiveRoot: folder.book?.root)
                        } label: { NativeServiceRow(service: service) }
                        .accessibilityIdentifier("service-\(service.id)")
                    }
                }
            } else {
                NativeEmptyState(symbol: "wrench.and.screwdriver", title: search.isEmpty ? "No service visits recorded" : "No matching visits", message: "Logged services, parts, labour, payments and invoice attachments appear here. Change the search or add a service from Garage.")
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
        }
        .searchable(text: $search, prompt: "Workshop, part, date or invoice")
        .navigationTitle("Service history").navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("serviceHistoryScreen")
    }
}

struct NativeServiceRow: View {
    let service: ServiceVisit
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(service.kindName ?? "Service visit").font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(NativeFormat.money(service.total)).monospacedDigit().font(.subheadline)
            }
            Text([service.date, service.workshop].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            Text("\(NativeFormat.number(service.odometerKm)) km · \(service.parts.count) parts · \(service.labour.count) labour items")
                .font(.caption).foregroundStyle(.secondary)
            if !service.photos.isEmpty {
                Label("\(service.photos.count) invoice attachment\(service.photos.count == 1 ? "" : "s")", systemImage: "paperclip")
                    .font(.caption).foregroundStyle(NativeTheme.blue)
            }
        }.padding(.vertical, 7).contentShape(Rectangle())
    }
}

struct NativeMaintenancePlanView: View {
    let snapshot: AnalyticsSnapshot?

    var body: some View {
        List {
            Section {
                Text("Due dates estimate future usage. Items without a logged replacement retain the provider schedule assumption; verify the actual work with your workshop.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Plan from analysis: \(NativeFormat.date(AnalyticsDate.parse(snapshot?.overview.generatedAt)))")
                    .font(.caption).foregroundStyle(.secondary)
                if let pace = snapshot?.overview.totals?.pace90d {
                    Text("Distance dates use the recent 90-day pace of \(NativeFormat.number(pace, digits: 1)) km/day.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Complete maintenance schedule") {
                if let schedule = snapshot?.overview.service, !schedule.isEmpty {
                    ForEach(schedule) { item in
                        VStack(alignment: .leading, spacing: 9) {
                            Text(item.item.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.headline)
                            LabeledContent("Due odometer", value: "\(NativeFormat.number(item.kmDue)) km")
                            LabeledContent("Estimated due date", value: item.due ?? "Unavailable")
                            if let distance = item.everyKM {
                                LabeledContent("Distance interval", value: "\(NativeFormat.number(distance)) km")
                            }
                            if let months = item.everyMonths {
                                LabeledContent("Time interval", value: "\(months) months")
                            }
                            if let days = item.daysLeft {
                                Text(days < 0 ? "At last analysis: \(-days) days past estimated due date" : "At last analysis: about \(days) days to estimated due date")
                                    .foregroundStyle(days < 0 ? Color.red : Color.secondary)
                            }
                            Text(item.trigger == "time" ? "Time is the earlier schedule trigger" : "Distance is the schedule trigger")
                                .font(.caption).foregroundStyle(.secondary)
                            if let done = item.lastDone {
                                Text("Last logged replacement: \(done.date ?? "date unavailable") · \(NativeFormat.number(done.km)) km")
                                    .font(.caption)
                            } else {
                                Text("Replacement history unconfirmed").font(.caption).foregroundStyle(.secondary)
                            }
                        }.font(.subheadline).padding(.vertical, 7)
                    }
                } else {
                    Text("No provider maintenance schedule is available in this analytical snapshot.").foregroundStyle(.secondary)
                }
            }
            Section("Dated reminders") {
                if let reminders = snapshot?.overview.reminders, !reminders.isEmpty {
                    ForEach(reminders) { reminder in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(reminder.note ?? "Maintenance reminder").font(.subheadline.weight(.semibold))
                            Text("\(reminder.date ?? "Date unavailable") · \(reminder.category?.replacingOccurrences(of: "_", with: " ") ?? "Other")")
                                .font(.caption).foregroundStyle(.secondary)
                            if let days = reminder.daysLeft, days < 0 {
                                Text("At last analysis: \(-days) days overdue").font(.caption).foregroundStyle(.red)
                            }
                        }.padding(.vertical, 4)
                    }
                } else { Text("No dated reminders in this snapshot.").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Maintenance plan").navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("maintenancePlanScreen")
    }
}

struct NativeReceiptView: View {
    let serviceID: String
    let photoName: String
    let archiveRoot: URL?
    @EnvironmentObject private var folder: FolderAccess
    @State private var image: UIImage?
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .accessibilityLabel("Service invoice attachment")
            } else if let error {
                NativeNotice(symbol: "doc.badge.ellipsis", title: "Attachment unavailable", message: error)
                    .padding()
            } else { ProgressView("Opening attachment…").padding(32) }
        }
        .navigationTitle("Invoice attachment").navigationBarTitleDisplayMode(.inline)
        .task(id: "\(folder.book?.root.absoluteString ?? "none")|\(serviceID)|\(photoName)") {
            image = nil
            error = nil
            guard let book = folder.book, book.root == archiveRoot, UUID(uuidString: serviceID) != nil,
                  !photoName.isEmpty, !photoName.hasPrefix("."), !photoName.contains("/"), !photoName.contains("\\") else {
                error = "This attachment reference could not be opened."
                return
            }
            let path = "log/services/\(serviceID)/\(photoName)"
            do {
                try await book.ensureDownloaded(path, timeout: 15)
                let bytes = try await Task.detached(priority: .userInitiated) { try book.read(path) }.value
                try Task.checkCancellation()
                guard folder.book?.root == book.root else { return }
                guard let decoded = UIImage(data: bytes) else {
                    error = "The saved attachment is not a supported image."
                    return
                }
                image = decoded
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, folder.book?.root == book.root else { return }
                self.error = "The original image could not be read. Check that its archive file has downloaded from iCloud."
            }
        }
    }
}

struct NativeRunningCostChart: View {
    let rates: RunningCostRates?
    @State private var selection: String?

    private struct Component: Identifiable {
        let id: String
        let rate: Double
    }
    private var components: [Component] {
        [("Fuel estimate", rates?.fuel), ("Services", rates?.service), ("Other", rates?.other)]
            .compactMap { name, value in
                guard let value, value.isFinite else { return nil }
                return Component(id: name, rate: value)
            }
    }
    var body: some View {
        if !components.isEmpty {
            Chart(components) { item in
                BarMark(x: .value("Component", item.id), y: .value("Rupees per km", item.rate))
                    .foregroundStyle(item.id == "Fuel estimate" ? NativeTheme.accent : NativeTheme.blue)
                    .opacity(selection == nil || selection == item.id ? 1 : 0.35)
                    .accessibilityLabel(item.id)
                    .accessibilityValue("\(NativeFormat.number(item.rate, digits: 2)) rupees per kilometre")
            }
            .chartXSelection(value: $selection)
            .chartYAxisLabel("₹/km")
            .frame(height: 170)
            if let selected = components.first(where: { $0.id == selection }) {
                Text("\(selected.id): ₹\(NativeFormat.number(selected.rate, digits: 2))/km")
                    .font(.caption).monospacedDigit()
            }
        }
    }
}
