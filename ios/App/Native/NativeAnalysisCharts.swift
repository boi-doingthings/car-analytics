import SwiftUI
import Charts

/// Bounded, selectable native plots shared by Lab and Fuel. No display timers or implicit animations.
struct LabPoint: Identifiable {
    let id: String
    let x: Double
    let y: Double
    var series = "Recorded"
    var detail = ""
    var tripID: String? = nil
    var segment: String? = nil

    init(id: String? = nil, x: Double, y: Double, series: String = "Recorded", detail: String = "", tripID: String? = nil, segment: String? = nil) {
        self.id = id ?? "\(series)|\(x)|\(y)|\(detail)"
        self.x = x; self.y = y; self.series = series; self.detail = detail; self.tripID = tripID; self.segment = segment
    }
}
struct LabBand: Identifiable {
    let id: String
    let x: Double
    let lower: Double
    let upper: Double
    var series = "Model interval"
    var segment: String? = nil
}
struct LabCategory: Identifiable {
    var id: String { label + "|" + series }
    let label: String
    let value: Double
    var series = "Recorded"
    var detail = ""
    var isMissing = false
}
struct LabHeatCell: Identifiable {
    var id: String { "\(column)|\(row)" }
    let column: Int
    let row: Int
    let value: Double?
    var detail = ""
}

enum LabWindow: String, CaseIterable, Identifiable {
    case month = "30 days", quarter = "90 days", year = "1 year", all = "All"
    var id: String { rawValue }
    var days: Int? {
        switch self { case .month: 30; case .quarter: 90; case .year: 365; case .all: nil }
    }
    func contains(_ date: Date?, anchor: Date?) -> Bool {
        guard let date else { return false }
        guard let days, let anchor else { return true }
        let calendar = AnalyticsDate.calendar
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: anchor))!
        let start = calendar.date(byAdding: .day, value: -days, to: end)!
        return date >= start && date < end
    }
    func containsMonth(_ date: Date?, anchor: Date?) -> Bool {
        guard let date else { return false }
        guard let days, let anchor else { return true }
        let calendar = AnalyticsDate.calendar
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: anchor))!
        let start = calendar.date(byAdding: .day, value: -days, to: end)!
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: date)!
        return date < end && monthEnd > start
    }
}

enum LabMath {
    static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    static func valid(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0 : nil } }
    /// Keep small nonzero telemetry visible instead of rounding it to a displayed zero.
    static func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        let magnitude = abs(value)
        if magnitude > 0, magnitude < 0.0001 {
            return value.formatted(.number.precision(.significantDigits(3...4)))
        }
        return NativeFormat.number(value, digits: magnitude > 0 && magnitude < 0.1 ? 4 : 2)
    }
    static func quantile(_ values: [Double], _ probability: Double) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let index = Double(sorted.count - 1) * min(max(probability, 0), 1)
        let lower = Int(index.rounded(.down)), upper = Int(index.rounded(.up))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (index - Double(lower))
    }
    static func bounded<T>(_ values: [T], maximum: Int = 300) -> [T] {
        guard values.count > maximum, maximum > 1 else { return values }
        return (0..<maximum).map { values[Int(Double($0) * Double(values.count - 1) / Double(maximum - 1))] }
    }
    static func hour(_ date: Date) -> Double {
        let c = AnalyticsDate.calendar.dateComponents([.hour, .minute], from: date)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    }
    static func weekday(_ date: Date) -> Int { (AnalyticsDate.calendar.component(.weekday, from: date) + 5) % 7 }
    static func hourLabel(_ hour: Double) -> String {
        let h = max(0, min(23, Int(hour)))
        return "\(h % 12 == 0 ? 12 : h % 12)\(h < 12 ? "am" : "pm")"
    }
    static func monthDate(_ value: String?) -> Date? {
        value.flatMap { AnalyticsDate.parse($0.count == 7 ? $0 + "-01" : $0) }
    }
}

struct LabWindowPicker: View {
    @Binding var selection: LabWindow
    let anchor: Date?
    var anchorLabel = "latest recorded journey"
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("History window", selection: $selection) {
                ForEach(LabWindow.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Text("Window ends at the \(anchorLabel): \(NativeFormat.date(anchor)). Saved model fits and reference diagrams retain their full training window.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct LabXYChart: View {
    let points: [LabPoint]
    var lines: [LabPoint] = []
    var bands: [LabBand] = []
    let xTitle: String
    let yTitle: String
    var timeAxis = false
    var logarithmicX = false
    var logarithmicY = false
    var snapshot: AnalyticsSnapshot? = nil
    var includeZeroY = true
    var includeZeroX = true
    @State private var selectedX: Double?

    private var plotted: [LabPoint] {
        LabMath.bounded(points.filter { $0.x.isFinite && $0.y.isFinite && (!logarithmicX || $0.x > 0) && (!logarithmicY || $0.y > 0) })
    }
    private var plottedLines: [LabPoint] {
        LabMath.bounded(lines.filter { $0.x.isFinite && $0.y.isFinite && (!logarithmicX || $0.x > 0) && (!logarithmicY || $0.y > 0) }, maximum: 600)
    }
    private var selected: LabPoint? {
        guard let selectedX else { return nil }
        return (plotted + plottedLines).min { abs($0.x - selectedX) < abs($1.x - selectedX) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if plotted.isEmpty && plottedLines.isEmpty {
                Text("Not enough recorded values for this plot.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                plot
                Text(timeAxis ? "Drag across the timeline to inspect a value." : "Tap or drag across the plot to inspect a displayed value.")
                    .font(.caption2).foregroundStyle(.secondary)
                if let selected {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(selected.series).font(.caption.weight(.semibold))
                        Text(selectionText(selected)).font(.subheadline).monospacedDigit()
                        if !selected.detail.isEmpty { Text(selected.detail).font(.caption).foregroundStyle(.secondary) }
                        if let snapshot, let id = selected.tripID, let trip = snapshot.trips.first(where: { $0.id == id }) {
                            NavigationLink("Inspect this journey") { NativeTripDetailView(trip: trip, snapshot: snapshot) }
                                .font(.subheadline)
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(NativeTheme.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                if points.count > plotted.count {
                    Text("\(plotted.count) evenly sampled points shown from \(points.count) values. Selection inspects plotted points; summaries use the full selected data.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                DisclosureGroup("Accessible plot values") {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(Array((plotted + plottedLines).prefix(40).enumerated()), id: \.offset) { _, point in
                            Text("\(point.series): \(selectionText(point))\(point.detail.isEmpty ? "" : " · " + point.detail)")
                                .font(.caption).textSelection(.enabled)
                        }
                        if plotted.count + plottedLines.count > 40 {
                            Text("First 40 displayed values listed. Use chart selection for other displayed values.").font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(.top, 8)
                }.font(.caption)
            }
        }
    }

    private var plot: some View {
        Chart {
            ForEach(LabMath.bounded(bands.filter { $0.x.isFinite && $0.lower.isFinite && $0.upper.isFinite }, maximum: 400)) { band in
                AreaMark(x: .value(xTitle, band.x), yStart: .value("Lower", band.lower), yEnd: .value("Upper", band.upper), series: .value("Band", band.segment ?? band.series))
                    .foregroundStyle(NativeTheme.blue.opacity(0.14))
            }
            ForEach(plottedLines) { point in
                LineMark(x: .value(xTitle, point.x), y: .value(yTitle, point.y), series: .value("Connection", point.segment ?? point.series))
                    .foregroundStyle(by: .value("Series", point.series)).lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(plotted) { point in
                PointMark(x: .value(xTitle, point.x), y: .value(yTitle, point.y))
                    .foregroundStyle(by: .value("Series", point.series)).symbol(.circle).symbolSize(28)
            }
            if let selected { RuleMark(x: .value(xTitle, selected.x)).foregroundStyle(.secondary).lineStyle(StrokeStyle(dash: [4])) }
        }
        .chartForegroundStyleScale(range: NativeTheme.chartColors)
        .chartXAxisLabel(xTitle).chartYAxisLabel(yTitle)
        .chartXScale(domain: .automatic(includesZero: includeZeroX && !timeAxis && !logarithmicX), type: logarithmicX ? .log : .linear)
        .chartYScale(domain: .automatic(includesZero: includeZeroY && !logarithmicY), type: logarithmicY ? .log : .linear)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(); AxisTick()
                AxisValueLabel {
                    if let x = value.as(Double.self) {
                        if timeAxis { Text(shortDate(x)).font(.caption2) }
                        else { Text(LabMath.number(x)).font(.caption2) }
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine(); AxisTick()
                AxisValueLabel { if let number = value.as(Double.self) { Text(LabMath.number(number)).font(.caption2) } }
            }
        }
        .chartXSelection(value: $selectedX)
        .frame(height: 235)
    }
    private func shortDate(_ timestamp: Double) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = AnalyticsDate.calendar.timeZone
        formatter.dateFormat = "d MMM"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
    private func selectionText(_ point: LabPoint) -> String {
        let x = timeAxis ? NativeFormat.date(Date(timeIntervalSince1970: point.x)) : LabMath.number(point.x)
        return "\(x) · \(LabMath.number(point.y)) \(yTitle)"
    }
}

/// Category labels live outside horizontal bars; long vertical series get a real scrollable canvas.
struct LabBarChart: View {
    let values: [LabCategory]
    let unit: String
    var horizontal = false
    var compactCategories = false
    var identifierPrefix: String? = nil
    @State private var selectedLabel: String?

    private var rows: [LabCategory] { values.filter { $0.value.isFinite || $0.isMissing } }
    private var valid: [LabCategory] { rows.filter { !$0.isMissing } }
    private var categories: [String] { unique(rows.map(\.label)) }
    private var series: [String] { unique(rows.map(\.series)) }
    private var ticks: [String] {
        guard compactCategories, categories.count > 8 else { return categories }
        let step = max(1, Int(ceil(Double(categories.count) / 6)))
        return categories.enumerated().compactMap { index, label in index % step == 0 || index == categories.count - 1 ? label : nil }
    }
    private func displayedValue(_ point: LabCategory) -> String {
        point.isMissing ? "Not recorded" : "\(LabMath.number(point.value)) \(unit)"
    }
    private var multipleSeries: Bool { series.count > 1 }
    private var colorDomain: [String] { multipleSeries ? series : categories }
    private var revision: String { ([unit] + categories + series).joined(separator: "|") }
    private func unique(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        return strings.filter { seen.insert($0).inserted }
    }
    private func colorKey(_ point: LabCategory) -> String { multipleSeries ? point.series : point.label }
    private func color(for key: String) -> Color {
        if compactCategories && !multipleSeries {
            return NativeTheme.teal.opacity(selectedLabel == nil || selectedLabel == key ? 1 : 0.4)
        }
        switch key {
        case "Harsh braking": return NativeTheme.coral
        case "Rapid acceleration": return NativeTheme.violet
        case "Overspeed alerts": return NativeTheme.amber
        default: break
        }
        let fullWeekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        if let weekday = LabMath.weekdays.firstIndex(of: key) ?? fullWeekdays.firstIndex(of: key) {
            return (NativeTheme.chartColors + [NativeTheme.green])[weekday]
        }
        // A deterministic key keeps the same category colour when filters remove its neighbours.
        let hash = key.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return NativeTheme.chartColors[Int(hash % UInt64(NativeTheme.chartColors.count))]
    }
    private func color(_ point: LabCategory) -> Color { color(for: colorKey(point)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if rows.isEmpty {
                Text("No values in this selection.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                if horizontal { horizontalRows }
                else {
                    Text(unit).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    if valid.isEmpty {
                        Text("No usable measurements in this selection. Missing categories are not zero.").font(.subheadline).foregroundStyle(.secondary)
                        categoryInspector
                    } else if compactCategories {
                        verticalChart.frame(height: 235).padding(.bottom, 26)
                        Text("Tap or drag across the profile, or choose an hour below. Unrecorded hours have no bar.").font(.caption).foregroundStyle(.secondary)
                        categoryInspector
                    } else if categories.count > 10 {
                        ScrollView(.horizontal) {
                            verticalChart.frame(width: CGFloat(categories.count) * 56, height: 235)
                                .padding(.trailing, 12)
                        }
                        Text("Swipe sideways for all \(categories.count) categories. Tap a bar to inspect its exact value.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else { verticalChart.frame(height: 235) }
                    selectionDetail
                }
                DisclosureGroup("Values and units") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(rows.prefix(60)) { point in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(point.label)\(multipleSeries ? " · " + point.series : ""): \(displayedValue(point))")
                                if !point.detail.isEmpty { Text(point.detail).foregroundStyle(.secondary) }
                            }.font(.caption)
                        }
                        if rows.count > 60 { Text("First 60 entries listed; select bars to inspect the remaining categories.").font(.caption) }
                    }.padding(.top, 8)
                }.font(.caption)
            }
        }
        .onChange(of: revision) { _, _ in selectedLabel = nil }
    }
    private var categoryInspector: some View {
        Menu {
            ForEach(categories, id: \.self) { label in
                Button(label) { selectedLabel = label }
            }
        } label: {
            HStack {
                Text(compactCategories ? "Inspect hour" : "Inspect category")
                Spacer()
                Text(selectedLabel ?? (compactCategories ? "Choose hour" : "Choose category"))
                Image(systemName: "chevron.up.chevron.down").font(.caption)
            }
            .font(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityIdentifier("\(identifierPrefix ?? "bar")-inspector")
    }
    private var horizontalRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(unit).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            ForEach(rows) { point in
                Button { selectedLabel = point.label } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(point.label).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Text(point.isMissing ? "Not recorded" : LabMath.number(point.value)).font(.subheadline.weight(.bold)).monospacedDigit()
                        }
                        if multipleSeries { Text(point.series).font(.caption).foregroundStyle(.secondary) }
                        if point.isMissing {
                            RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4])).frame(height: 14)
                                .accessibilityHidden(true)
                        } else { horizontalBar(point) }
                        if selectedLabel == point.label, !point.detail.isEmpty { Text(point.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(color(point).opacity(selectedLabel == point.label ? 0.13 : 0.045), in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(color(point).opacity(selectedLabel == point.label ? 0.65 : 0), lineWidth: 1) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(point.label)\(multipleSeries ? " · " + point.series : "")")
                .accessibilityValue("\(displayedValue(point))\(point.detail.isEmpty ? "" : " · " + point.detail)")
                .accessibilityIdentifier(identifierPrefix.map { "\($0)-\(point.label)" } ?? "bar-\(point.id)")
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(selectedLabel == point.label ? .isSelected : [])
            }
        }
    }
    private func horizontalBar(_ point: LabCategory) -> some View {
        let low = min(0, valid.map(\.value).min() ?? 0)
        let high = max(0, valid.map(\.value).max() ?? 0)
        let span = max(high - low, 0.000000001)
        let origin = (min(0, point.value) - low) / span
        let fraction = abs(point.value) / span
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(color(point).opacity(0.12))
                if point.value != 0 {
                    RoundedRectangle(cornerRadius: 6).fill(color(point).gradient)
                        .frame(width: max(2, geometry.size.width * fraction))
                        .offset(x: geometry.size.width * origin)
                }
                if low < 0 {
                    Rectangle().fill(.secondary.opacity(0.6)).frame(width: 1)
                        .offset(x: geometry.size.width * (-low / span))
                }
            }
        }.frame(height: 14).accessibilityHidden(true)
    }
    private var verticalChart: some View {
        Chart(valid) { point in
            BarMark(x: .value("Category", point.label), y: .value(unit, point.value))
                .foregroundStyle(by: .value("Category colour", colorKey(point)))
                .position(by: .value("Series", point.series))
                .cornerRadius(4)
        }
        .chartXScale(domain: categories)
        .chartForegroundStyleScale(domain: colorDomain, range: colorDomain.map { color(for: $0) })
        .chartLegend(multipleSeries ? .visible : .hidden)
        .chartXAxis {
            AxisMarks(values: ticks) { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(label).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .chartXAxis(compactCategories ? .hidden : .visible)
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel { if let number = value.as(Double.self) { Text(LabMath.number(number)).font(.caption2) } }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if compactCategories, let frame = proxy.plotFrame {
                    let plot = geometry[frame]
                    ForEach(ticks, id: \.self) { label in
                        if let x = proxy.position(forX: label) {
                            Text(label).font(.caption2).foregroundStyle(.secondary)
                                .fixedSize()
                                .position(x: plot.minX + x, y: plot.maxY + 14)
                                .accessibilityIdentifier("\(identifierPrefix ?? "bar")-tick-\(label)")
                        }
                    }
                }
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let frame = proxy.plotFrame else { return }
                        let plot = geometry[frame]
                        guard plot.contains(location) else { return }
                        selectedLabel = proxy.value(atX: location.x - plot.minX, as: String.self)
                    }
                    .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { value in
                        guard compactCategories, abs(value.translation.width) > abs(value.translation.height),
                              let frame = proxy.plotFrame else { return }
                        let plot = geometry[frame]
                        guard plot.contains(value.location) else { return }
                        selectedLabel = proxy.value(atX: value.location.x - plot.minX, as: String.self)
                    })
            }
        }
        .id(revision)
        .accessibilityLabel("\(unit) by category. Tap a bar or expand Values and units for exact values.")
    }
    @ViewBuilder private var selectionDetail: some View {
        if let selectedLabel {
            ForEach(rows.filter { $0.label == selectedLabel }) { point in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(point.label)\(multipleSeries ? " · " + point.series : ""): \(displayedValue(point))")
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .accessibilityIdentifier("\(identifierPrefix ?? "bar")-selection")
                    if !point.detail.isEmpty { Text(point.detail).font(.caption).foregroundStyle(.secondary) }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(color(point).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityElement(children: .contain).accessibilityIdentifier("barSelectionSummary")
            }
        }
    }
}

struct LabHeatmap: View {
    let columns: [String]
    let rows: [String]
    let cells: [LabHeatCell]
    var signed = false
    var unit = ""
    @State private var selectedColumn = 0
    @State private var selectedRow = 0

    private var columnTicks: [Double] {
        let step = max(1, Int(ceil(Double(columns.count) / 4)))
        return stride(from: 0, to: columns.count, by: step).map { Double($0) + 0.5 }
    }
    private var rowTicks: [Double] {
        let step = max(1, Int(ceil(Double(rows.count) / 8)))
        return stride(from: 0, to: rows.count, by: step).map { Double($0) + 0.5 }
    }
    private var selected: LabHeatCell? { cells.first { $0.column == selectedColumn && $0.row == selectedRow } }
    private var maximum: Double { max(1, cells.compactMap(\.value).map(abs).max() ?? 1) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Chart(cells) { cell in
                if let value = cell.value, value.isFinite {
                    RectangleMark(xStart: .value("Column", Double(cell.column)), xEnd: .value("Column end", Double(cell.column + 1)),
                                  yStart: .value("Row", Double(cell.row)), yEnd: .value("Row end", Double(cell.row + 1)))
                        .foregroundStyle((signed ? (value < 0 ? NativeTheme.blue : NativeTheme.amber) : NativeTheme.teal)
                            .opacity(0.12 + 0.88 * (signed ? abs(value) : log1p(max(value, 0))) / (signed ? maximum : log1p(maximum))))
                }
            }
            .chartXScale(domain: 0...Double(max(columns.count, 1)))
            .chartYScale(domain: 0...Double(max(rows.count, 1)))
            .chartXAxis {
                AxisMarks(values: columnTicks) { value in
                    AxisValueLabel { if let index = value.as(Double.self), columns.indices.contains(Int(index)) { Text(String(columns[Int(index)].prefix(8))).font(.caption2) } }
                }
            }
            .chartYAxis {
                AxisMarks(values: rowTicks) { value in
                    AxisValueLabel { if let index = value.as(Double.self), rows.indices.contains(Int(index)) { Text(rows[Int(index)]).font(.caption2) } }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            guard let frame = proxy.plotFrame else { return }
                            let plot = geometry[frame]
                            let x = location.x - plot.minX, y = location.y - plot.minY
                            guard x >= 0, y >= 0, x <= plot.width, y <= plot.height,
                                  let column = proxy.value(atX: x, as: Double.self),
                                  let row = proxy.value(atY: y, as: Double.self) else { return }
                            selectedColumn = min(max(0, Int(column)), max(0, columns.count - 1))
                            selectedRow = min(max(0, Int(row)), max(0, rows.count - 1))
                        }
                }
            }
            .frame(height: max(180, min(340, Double(rows.count) * 30)))
            .accessibilityLabel("Selectable intensity diagram. Use the row and column controls below to inspect exact values.")
            HStack {
                Picker("Row", selection: $selectedRow) { ForEach(rows.indices, id: \.self) { Text(rows[$0]).tag($0) } }.pickerStyle(.menu)
                Picker("Column", selection: $selectedColumn) { ForEach(columns.indices, id: \.self) { Text(columns[$0]).tag($0) } }.pickerStyle(.menu)
            }.font(.caption)
            if rows.indices.contains(selectedRow), columns.indices.contains(selectedColumn) {
                Text("\(rows[selectedRow]) × \(columns[selectedColumn]): \(LabMath.number(selected?.value)) \(unit)")
                    .font(.subheadline).monospacedDigit()
                if let detail = selected?.detail, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

struct LabSpreadRow: Identifiable {
    var id: String { label }
    let label: String
    let low: Double
    let q1: Double
    let median: Double
    let q3: Double
    let high: Double
    var detail = ""
}
struct LabSpreadChart: View {
    let rows: [LabSpreadRow]
    let unit: String
    @State private var selection: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Chart(rows) { row in
                RuleMark(xStart: .value("Low", row.low), xEnd: .value("High", row.high), y: .value("Group", row.label))
                    .foregroundStyle(NativeTheme.blue)
                BarMark(xStart: .value("Lower quartile", row.q1), xEnd: .value("Upper quartile", row.q3), y: .value("Group", row.label), height: .fixed(18))
                    .foregroundStyle(NativeTheme.violet.opacity(0.35))
                PointMark(x: .value("Median", row.median), y: .value("Group", row.label))
                    .symbol(.diamond).foregroundStyle(.primary).symbolSize(48)
            }
            .chartXAxisLabel(unit)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel { if let number = value.as(Double.self) { Text(LabMath.number(number)).font(.caption2) } }
                }
            }
            .chartYSelection(value: $selection)
            .frame(height: max(130, min(300, Double(rows.count) * 65)))
            Text("Diamond: median · thick band: middle 50% · line: displayed outer range. Select a row for values.")
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(selection == nil ? rows : rows.filter { $0.label == selection }) { row in
                Text("\(row.label): \(LabMath.number(row.median)) \(unit) median; IQR \(LabMath.number(row.q1))–\(LabMath.number(row.q3)); range \(LabMath.number(row.low))–\(LabMath.number(row.high)). \(row.detail)")
                    .font(.caption)
            }
        }
    }
}
