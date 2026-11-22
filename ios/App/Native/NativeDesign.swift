import SwiftUI

/// Shared instruments for the native screens. Semantic surfaces adapt to light mode and large text.
enum NativeTheme {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.94, green: 0.57, blue: 0.13, alpha: 1)
            : UIColor(red: 0.61, green: 0.30, blue: 0.04, alpha: 1)
    })
    static let blue = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.40, green: 0.66, blue: 0.98, alpha: 1)
            : UIColor(red: 0.14, green: 0.40, blue: 0.73, alpha: 1)
    })
    /// High-contrast fill for prominent actions with the system’s white button label.
    static let action = Color(red: 0.12, green: 0.36, blue: 0.66)
    static let navy = Color(red: 0.06, green: 0.10, blue: 0.17)
}

struct NativeCard<Content: View>: View {
    let title: String?
    let symbol: String?
    @ViewBuilder let content: Content

    init(title: String? = nil, symbol: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title {
                HStack(spacing: 8) {
                    if let symbol { Image(systemName: symbol).foregroundStyle(NativeTheme.accent) }
                    Text(title).font(.headline)
                }
                .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct NativeMetric: View {
    let title: String
    let value: String
    var unit: String? = nil
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 4) { valueLabel; unitLabel }
                VStack(alignment: .leading, spacing: 1) { valueLabel; unitLabel }
            }
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var valueLabel: some View { Text(value).font(.title2.weight(.semibold)).monospacedDigit() }
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
    var tint: Color = NativeTheme.accent

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
