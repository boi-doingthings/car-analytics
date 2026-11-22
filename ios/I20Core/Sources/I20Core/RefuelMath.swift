import Foundation

public enum RefuelInputError: Error, Equatable {
    case needTwo        // fewer than two of litres / amount / rate
    case nonPositive    // a given value is zero, negative or not a number
    case inconsistent   // all three given but litres * rate differs from amount by more than 1 %
}

public enum RefuelMath {
    /// Fills in the missing one of litres / amount (rupees) / rate (rupees per litre).
    public static func complete(litres: Double?, amount: Double?, rate: Double?)
        -> Result<(litres: Double, amount: Double, rate: Double), RefuelInputError> {
        let given = [litres, amount, rate].compactMap { $0 }
        if given.contains(where: { !($0 > 0) || !$0.isFinite }) { return .failure(.nonPositive) }
        switch (litres, amount, rate) {
        case let (l?, a?, r?):
            return abs(l * r - a) / a > 0.01 ? .failure(.inconsistent) : .success((l, a, r))
        case let (nil, a?, r?): return .success((a / r, a, r))
        case let (l?, nil, r?): return .success((l, l * r, r))
        case let (l?, a?, nil): return .success((l, a, a / l))
        default: return .failure(.needTwo)
        }
    }

    /// Parses a typed number: strips ₹ and spaces; "1,234.5" (commas are thousands separators);
    /// "33,23" (a single comma, no dot, at most two digits after it is a decimal comma). Nil if not a number.
    public static func parse(_ text: String) -> Double? {
        var s = text.replacingOccurrences(of: "₹", with: "")
        s.removeAll { $0.isWhitespace }
        guard !s.isEmpty else { return nil }
        if !s.contains(".") {
            let parts = s.split(separator: ",", omittingEmptySubsequences: false)
            if parts.count == 2, (1...2).contains(parts[1].count) { s = parts[0] + "." + parts[1] }
        }
        s.removeAll { $0 == "," }
        // Only plain decimals: rejects "nan", "inf", hex floats, exponents.
        guard s.range(of: #"^-?(\d+\.?\d*|\.\d+)$"#, options: .regularExpression) != nil else { return nil }
        return Double(s)
    }
}

/// A message when the typed odometer is below the previous fill's; the entry can still be saved.
public func odometerWarning(_ km: Double, previous: Double?) -> String? {
    guard let previous, km < previous else { return nil }
    let f = { (v: Double) in String(format: "%.0f", v) }
    return "Odometer \(f(km)) km is lower than the previous fill (\(f(previous)) km)."
}
