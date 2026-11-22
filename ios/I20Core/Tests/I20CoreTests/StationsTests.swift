import Testing
@testable import I20Core

@Suite struct StationsTests {
    func fill(_ station: String, _ date: String = "2026-01-01", lat: Double? = nil, lon: Double? = nil) -> Refuel {
        Refuel(date: date, station: station, lat: lat, lon: lon)
    }

    var past: [Refuel] {
        [fill("Test Pump North", lat: 25.30, lon: 87.10), fill("Test Pump North", lat: 25.30, lon: 87.10),
         fill("Sector Synthetic South", lat: 25.50, lon: 87.50), fill("Sector 12 | Ring", lat: 25.90, lon: 87.90),
         fill("Sector 12 | Ring", lat: 25.90, lon: 87.90), fill("Sector 12 | Ring"),
         fill("Old Pump"), fill("  ")]
    }

    @Test func prefixMatchesFirst() {
        let out = Stations.suggest(past: past, near: nil, prefix: "sec")
        #expect(Array(out.prefix(2)) == ["Sector 12 | Ring", "Sector Synthetic South"])  // by count
        #expect(Set(out) == ["Test Pump North", "Sector Synthetic South", "Sector 12 | Ring", "Old Pump"])
        #expect(Stations.suggest(past: past, near: nil, prefix: "SEC").first == "Sector 12 | Ring")
    }

    @Test func nearestRanksFirst() {
        let out = Stations.suggest(past: past, near: (25.301, 87.101), prefix: "")
        #expect(out.first == "Test Pump North")
        #expect(out == ["Test Pump North", "Sector Synthetic South", "Sector 12 | Ring", "Old Pump"])  // no-coords last
    }

    @Test func prefixBeatsDistance() {
        let out = Stations.suggest(past: past, near: (25.301, 87.101), prefix: "sec")
        #expect(out == ["Sector Synthetic South", "Sector 12 | Ring", "Test Pump North", "Old Pump"])
    }

    @Test func distinctAndEmpty() {
        #expect(Stations.suggest(past: [], near: nil, prefix: "x").isEmpty)
        #expect(Stations.suggest(past: past, near: nil, prefix: "").filter { $0 == "Test Pump North" }.count == 1)
    }
}
