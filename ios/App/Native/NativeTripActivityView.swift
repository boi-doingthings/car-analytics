import SwiftUI
import Charts

/// Month/day exploration independent of the web dashboard. Empty archive cells are never called zero driving.
struct NativeTripActivityView: View {
    let snapshot: AnalyticsSnapshot
    @State private var selectedMonth: String?
    @State private var selectedDay: String?
    @State private var selectedChartDate: Date?
    @State private var chartWindowEnd: Int?

    private var calendar: Calendar { AnalyticsDate.calendar }
    private var monthKey: String { selectedMonth ?? snapshot.history.monthly.last?.key ?? "" }
    private var monthDate: Date? { AnalyticsDate.parse(monthKey + "-01") }
    private var monthTrips: [NativeTrip] { monthKey.isEmpty ? [] : snapshot.trips.filter { $0.day.hasPrefix(monthKey) } }
    private var chosenTrips: [NativeTrip] {
        if let selectedDay { return monthTrips.filter { $0.day == selectedDay } }
        return monthTrips
    }
    private var monthBuckets: [DrivingBucket] { snapshot.history.daily.filter { $0.key.hasPrefix(monthKey) } }
    private var byDay: [String: DrivingBucket] { Dictionary(monthBuckets.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                NativeCard(title: "Kilometres by month", symbol: "chart.bar.xaxis") {
                    if snapshot.history.monthly.isEmpty {
                        Text("No dated trip summaries are available yet.").foregroundStyle(.secondary)
                    } else {
                        monthlyChart
                        if snapshot.history.monthly.count > 24 {
                            HStack {
                                Button("Earlier months") { chartWindowEnd = max(0, endIndex - 24) }
                                    .disabled(endIndex < 24)
                                Spacer()
                                Text("\(plottedMonths.count) of \(snapshot.history.monthly.count) recorded months").font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Button("Later months") { chartWindowEnd = min(snapshot.history.monthly.count - 1, endIndex + 24) }
                                    .disabled(endIndex >= snapshot.history.monthly.count - 1)
                            }.font(.caption).frame(minHeight: 44)
                        }
                        Text("Tap a month to open its calendar and journeys. Distances sum the available provider trip records; missing dates are not filled with zero.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let bucket = snapshot.history.monthly.first(where: { $0.key == monthKey }) {
                            HStack(alignment: .top, spacing: 16) {
                                NativeMetric(title: monthTitle(bucket.date), value: NativeFormat.number(bucket.distanceKM, digits: 1), unit: bucket.distanceKM == nil ? nil : "km", caption: "\(bucket.tripCount) archived drives")
                                NativeMetric(title: "Time", value: NativeFormat.duration(bucket.elapsedMinutes), caption: "Recorded trip durations")
                            }
                        }
                    }
                }
                calendarCard
                NativeCard(title: selectedDay.map { "Recorded journeys · \($0)" } ?? "Journeys in this month", symbol: "steeringwheel") {
                    if let selectedDay, let bucket = byDay[selectedDay] {
                        HStack(alignment: .top, spacing: 16) {
                            NativeMetric(title: "Recorded distance", value: NativeFormat.number(bucket.distanceKM, digits: 1), unit: bucket.distanceKM == nil ? nil : "km", caption: "\(bucket.tripCount) archived drives")
                            NativeMetric(title: "Idle share", value: NativeFormat.percent(bucket.idleShare), caption: "Moving + idle denominator")
                        }
                    }
                    if chosenTrips.isEmpty {
                        Text("No trips are archived for this selection. That does not establish that the car was not driven.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ForEach(chosenTrips) { trip in
                            NavigationLink { NativeTripDetailView(trip: trip, snapshot: snapshot) } label: {
                                HStack {
                                    NativeTripRow(trip: trip)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).accessibilityIdentifier("historyTrip-\(trip.id)")
                            if trip.id != chosenTrips.last?.id { Divider() }
                        }
                    }
                }
            }.padding(16)
        }
        .background(NativeTheme.background)
        .environment(\.timeZone, calendar.timeZone)
        .environment(\.calendar, calendar)
        .navigationTitle("Driving activity").navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedChartDate) { _, date in
            guard let date else { return }
            let key = dayKey(date)
            selectedMonth = String(key.prefix(7))
            selectedDay = nil
        }
    }

    private var endIndex: Int { max(0, min(snapshot.history.monthly.count - 1, chartWindowEnd ?? snapshot.history.monthly.count - 1)) }
    private var plottedMonths: [DrivingBucket] {
        guard !snapshot.history.monthly.isEmpty else { return [] }
        return Array(snapshot.history.monthly[max(0, endIndex - 23)...endIndex])
    }

    private var monthlyChart: some View {
        Chart(plottedMonths) { bucket in
            if let date = bucket.date, let distance = bucket.distanceKM {
                BarMark(x: .value("Month", date, unit: .month), y: .value("Recorded kilometres", distance))
                    .foregroundStyle(bucket.key == monthKey ? NativeTheme.accent : NativeTheme.blue)
                    .cornerRadius(4)
            }
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
        .chartYAxisLabel("km")
        .chartXSelection(value: $selectedChartDate)
        .frame(height: 190)
        .accessibilityLabel("Monthly distance from archived trip summaries")
        .accessibilityIdentifier("monthlyDistanceChart")
    }

    private var calendarCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "calendar").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NativeTheme.indigo).frame(width: 30, height: 30)
                    .background(NativeTheme.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                Text("Month and day explorer").font(.headline)
            }
            Picker("Month", selection: Binding(get: { monthKey }, set: { value in
                selectedMonth = value; selectedDay = nil
                if !plottedMonths.contains(where: { $0.key == value }),
                   let index = snapshot.history.monthly.firstIndex(where: { $0.key == value }) { chartWindowEnd = index }
            })) {
                ForEach(months, id: \.self) { key in
                    Text(monthTitle(AnalyticsDate.parse(key + "-01"))).tag(key)
                }
            }
            .pickerStyle(.menu).accessibilityIdentifier("historyMonthPicker")
            let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(weekdayNames.enumerated()), id: \.offset) { _, name in
                    Text(name).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity).accessibilityHidden(true)
                }
                ForEach(0..<leadingBlankCount, id: \.self) { _ in Color.clear.frame(height: 44).accessibilityHidden(true) }
                ForEach(monthDates, id: \.self) { date in
                    let key = dayKey(date)
                    let bucket = byDay[key]
                    Button {
                        selectedDay = selectedDay == key ? nil : key
                    } label: {
                        Text("\(calendar.component(.day, from: date))")
                            .font(.subheadline.monospacedDigit())
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(dayColor(bucket), in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selectedDay == key ? NativeTheme.accent : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(NativeFormat.date(date)), \(bucket.map { "\($0.tripCount) archived drives, \(NativeFormat.number($0.distanceKM, digits: 1)) kilometres" } ?? "no trips archived")")
                    .accessibilityIdentifier("historyDay-\(key)")
                }
            }
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(.secondary.opacity(0.07)).frame(width: 12, height: 12)
                Text("No trip record")
                RoundedRectangle(cornerRadius: 3).fill(NativeTheme.blue.opacity(0.4)).frame(width: 12, height: 12)
                Text("Recorded km")
            }.font(.caption2).foregroundStyle(.secondary)
            Text("Stronger colour means more recorded distance within this month. Blank days have no trip records; the archive does not prove they were parked days.")
                .font(.caption).foregroundStyle(.secondary)
            if selectedDay != nil {
                Button("Show whole month") { selectedDay = nil }.font(.subheadline).frame(minHeight: 44)
                    .accessibilityIdentifier("historyWholeMonth")
            }
        }
        .padding(14).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 22))
    }

    private var months: [String] {
        guard let first = snapshot.history.firstDate, let last = snapshot.history.lastDate,
              var date = calendar.dateInterval(of: .month, for: first)?.start,
              let end = calendar.dateInterval(of: .month, for: last)?.start else { return [] }
        var result: [String] = []
        while date <= end && result.count < 1_200 {
            result.append(String(dayKey(date).prefix(7)))
            guard let next = calendar.date(byAdding: .month, value: 1, to: date) else { break }
            date = next
        }
        return Array(result.reversed())
    }
    private var monthDates: [Date] {
        guard let date = monthDate, let range = calendar.range(of: .day, in: .month, for: date) else { return [] }
        return range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: date) }
    }
    private var leadingBlankCount: Int {
        monthDate.map { (calendar.component(.weekday, from: $0) + 5) % 7 } ?? 0
    }
    private var weekdayNames: [String] {
        let names = calendar.veryShortStandaloneWeekdaySymbols
        return Array(names.dropFirst()) + [names[0]]
    }
    private func dayKey(_ date: Date) -> String { ISTClock.day(date) }
    private func monthTitle(_ date: Date?) -> String {
        guard let date else { return "Month unavailable" }
        let f = DateFormatter(); f.locale = .autoupdatingCurrent; f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return f.string(from: date)
    }
    private func dayColor(_ bucket: DrivingBucket?) -> Color {
        guard let bucket else { return .secondary.opacity(0.07) }
        guard let km = bucket.distanceKM else { return NativeTheme.amber.opacity(0.18) }
        let maximum = monthBuckets.compactMap(\.distanceKM).max() ?? 1
        return NativeTheme.blue.opacity(0.12 + 0.48 * min(1, max(0, km / max(1, maximum))))
    }
}
