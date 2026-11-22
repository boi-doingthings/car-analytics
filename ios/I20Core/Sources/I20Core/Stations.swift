import Foundation

public enum Stations {
    /// Station names from the owner's own past fills (never Apple Maps names).
    /// Distinct names; those starting with `prefix` (case-insensitive) first, then the rest. Within each group:
    /// nearest to `near` first (stations with no coordinates after those with), then most-used, then name.
    public static func suggest(past: [Refuel], near: (lat: Double, lon: Double)?, prefix: String) -> [String] {
        struct Info { var count = 0; var latest = ""; var coord: (lat: Double, lon: Double)? }
        var info: [String: Info] = [:]
        for r in past {
            let name = r.station.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { continue }
            var i = info[name] ?? Info()
            i.count += 1
            if let la = r.lat, let lo = r.lon, r.date >= i.latest || i.coord == nil {
                i.coord = (la, lo)
                i.latest = r.date
            }
            info[name] = i
        }
        let p = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        func distance(_ n: String) -> Double? {
            guard let near, let c = info[n]?.coord else { return nil }
            return haversineKm(near.lat, near.lon, c.lat, c.lon)
        }
        func before(_ a: String, _ b: String) -> Bool {
            if near != nil {
                switch (distance(a), distance(b)) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            }
            if info[a]!.count != info[b]!.count { return info[a]!.count > info[b]!.count }
            return a < b
        }
        let names = info.keys.sorted(by: before)
        return names.filter { $0.lowercased().hasPrefix(p) } + names.filter { !$0.lowercased().hasPrefix(p) }
    }

    static func haversineKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0, rad = Double.pi / 180
        let dLat = (lat2 - lat1) * rad, dLon = (lon2 - lon1) * rad
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * rad) * cos(lat2 * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }
}
