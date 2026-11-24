import SwiftUI

/// Shared instruments for the native screens. Semantic surfaces adapt to light mode and large text.
enum NativeTheme {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let border = Color(uiColor: .separator).opacity(0.22)

    // Chromatic inks darken on light surfaces and brighten on dark surfaces.
    // Amber denotes fuel/uncertainty; coral denotes event or acceleration exposure.
    static let blue = adaptive(light: (0.02, 0.37, 0.83), dark: (0.31, 0.65, 1.00))
    static let teal = adaptive(light: (0.00, 0.43, 0.45), dark: (0.27, 0.84, 0.79))
    static let indigo = adaptive(light: (0.31, 0.27, 0.75), dark: (0.61, 0.57, 1.00))
    static let violet = adaptive(light: (0.49, 0.23, 0.76), dark: (0.77, 0.55, 1.00))
    static let purple = violet
    static let coral = adaptive(light: (0.76, 0.22, 0.23), dark: (1.00, 0.52, 0.49))
    static let amber = adaptive(light: (0.58, 0.36, 0.03), dark: (1.00, 0.73, 0.24))
    static let green = adaptive(light: (0.16, 0.45, 0.26), dark: (0.37, 0.85, 0.57))
    static let accent = blue
    /// White-label action fills remain darker than the chromatic text/line inks.
    static let action = adaptive(light: (0.02, 0.37, 0.83), dark: (0.05, 0.38, 0.78))
    static let navy = Color(red: 0.06, green: 0.10, blue: 0.17)
    /// Stable categorical order. Named semantic series should use their explicit colour.
    static let chartColors: [Color] = [blue, teal, violet, coral, amber, indigo]

    static func iconTint(for symbol: String?) -> Color {
        guard let symbol else { return blue }
        if symbol.contains("exclamationmark") { return amber }
        if symbol.hasPrefix("fuelpump") || symbol.hasPrefix("drop") { return amber }
        if symbol.hasPrefix("wrench") || symbol.hasPrefix("checkmark.shield") { return teal }
        if symbol.hasPrefix("indianrupeesign") || symbol.hasPrefix("receipt") { return green }
        if symbol.hasPrefix("clock") || symbol.hasPrefix("calendar") || symbol.hasPrefix("book") { return indigo }
        if symbol.hasPrefix("waveform") || symbol.hasPrefix("engine") { return coral }
        if symbol.hasPrefix("square.grid") || symbol.hasPrefix("point.3") || symbol == "function" { return violet }
        return blue
    }

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: value.0, green: value.1, blue: value.2, alpha: 1)
        })
    }
}

struct NativeCard<Content: View>: View {
    let title: String?
    let symbol: String?
    let iconTint: Color?
    @ViewBuilder let content: Content

    init(title: String? = nil, symbol: String? = nil, tint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.iconTint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title {
                HStack(alignment: .center, spacing: 10) {
                    if let symbol {
                        let tint = iconTint ?? NativeTheme.iconTint(for: symbol)
                        Image(systemName: symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(tint)
                            .frame(width: 30, height: 30)
                            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .accessibilityHidden(true)
                    }
                    Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(NativeTheme.border, lineWidth: 0.5))
    }
}

struct NativeMetric: View {
    let title: String
    let value: String
    var unit: String? = nil
    var caption: String? = nil
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 4) { valueLabel; unitLabel }
                VStack(alignment: .leading, spacing: 1) { valueLabel; unitLabel }
            }
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var valueLabel: some View { Text(value).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit().foregroundStyle(tint ?? .primary) }
    @ViewBuilder private var unitLabel: some View { if let unit { Text(unit).font(.caption).foregroundStyle(.secondary) } }
}

struct NativeEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol).font(.title).foregroundStyle(NativeTheme.blue).accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct NativeNotice: View {
    let symbol: String
    let title: String
    let message: String
    var tint: Color = NativeTheme.amber

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
    }
}

enum NativeFormat {
    static func number(_ value: Double?, digits: Int = 0) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        return value.formatted(.number.precision(.fractionLength(0...digits)))
    }

    static func duration(_ minutes: Double?) -> String {
        guard let minutes, minutes.isFinite, minutes >= 0, minutes.rounded() < Double(Int.max) else { return "Unavailable" }
        let total = Int(minutes.rounded())
        if total < 60 { return "\(total) min" }
        let hours = total / 60, remainder = total % 60
        return remainder == 0 ? "\(hours) h" : "\(hours) h \(remainder) min"
    }

    static func money(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        return value.formatted(.currency(code: "INR").precision(.fractionLength(0)))
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        return value.formatted(.percent.precision(.fractionLength(0)))
    }

    static func date(_ date: Date?, includeTime: Bool = false) -> String {
        guard let date else { return "Date unavailable" }
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.timeZone = TimeZone(identifier: "Asia/Kolkata")
        f.setLocalizedDateFormatFromTemplate(includeTime ? "d MMM yyyy jm" : "d MMM yyyy")
        return f.string(from: date)
    }

    static func tripTitle(_ trip: NativeTrip) -> String {
        let from = trip.origin?.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = trip.destination?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let from, !from.isEmpty, let to, !to.isEmpty { return "\(from) → \(to)" }
        if let to, !to.isEmpty { return "Journey to \(to)" }
        if let from, !from.isEmpty { return "Journey from \(from)" }
        return "Recorded journey"
    }
}
