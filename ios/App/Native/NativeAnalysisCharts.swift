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
        return "\(h % 12 == 0 ? 12 : h % 12)\(h < 12 ? "a" : "p")"
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
        .chartForegroundStyleScale(range: [NativeTheme.accent, NativeTheme.blue, .teal, .purple, .pink])
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

struct LabBarChart: View {
    let values: [LabCategory]
    let unit: String
    var horizontal = false
    @State private var selectedLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if values.isEmpty { Text("No values in this selection.").font(.subheadline).foregroundStyle(.secondary) }
            else {
                Chart(values.filter { $0.value.isFinite }) { point in
                    if horizontal {
                        BarMark(x: .value(unit, point.value), y: .value("Category", point.label))
                            .foregroundStyle(by: .value("Series", point.series))
                            .position(by: .value("Series", point.series))
                    } else {
                        BarMark(x: .value("Category", point.label), y: .value(unit, point.value))
                            .foregroundStyle(by: .value("Series", point.series))
                            .position(by: .value("Series", point.series))
                    }
                }
                .chartForegroundStyleScale(range: [NativeTheme.accent, NativeTheme.blue, .teal, .purple])
                .chartXSelection(value: horizontal ? .constant(nil) : $selectedLabel)
                .chartYSelection(value: horizontal ? $selectedLabel : .constant(nil))
                .frame(height: horizontal ? max(170, min(360, Double(Set(values.map(\.label)).count) * 34)) : 205)
                if let selectedLabel {
                    ForEach(values.filter { $0.label == selectedLabel }) { point in
                        Text("\(point.label) · \(point.series): \(LabMath.number(point.value)) \(unit)\(point.detail.isEmpty ? "" : " · " + point.detail)")
                            .font(.caption).monospacedDigit()
                    }
                }
                DisclosureGroup("Values and units") {
                    ForEach(values.prefix(60)) { point in
                        LabeledContent("\(point.label) · \(point.series)", value: "\(LabMath.number(point.value)) \(unit)")
                            .font(.caption)
                    }
                }.font(.caption)
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
                        .foregroundStyle((signed && value < 0 ? NativeTheme.blue : NativeTheme.accent)
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
                    .foregroundStyle(NativeTheme.accent.opacity(0.5))
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
