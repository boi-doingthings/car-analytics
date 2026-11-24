import XCTest
@testable import I20Logbook

final class GarageCostEvidenceTests: XCTestCase {
    func test_legacyZeroFuelWithoutAModelDoesNotBecomeKnownCost() {
        let legacy = RunningCost(perKM: RunningCostRates(fuel: 0, service: 1, other: 0.5, total: 1.5))
        let result = GarageCostEvidence(cost: legacy, fuel: nil).rates
        XCTAssertNil(result.fuel)
        XCTAssertNil(result.total)
        XCTAssertEqual(result.service, 1)
        XCTAssertEqual(result.other, 0.5)
    }

    func test_combinedRateNeedsEveryComponentAndUsesFuelModelEvidence() {
        let fuel = FuelTotals(modelCostPerKM: 7)
        let legacy = RunningCost(perKM: RunningCostRates(fuel: 0, service: 1, other: 0.5, total: 1.5))
        XCTAssertEqual(GarageCostEvidence(cost: legacy, fuel: fuel).rates.total, 8.5)
        let incomplete = RunningCost(perKM: RunningCostRates(service: 1))
        XCTAssertNil(GarageCostEvidence(cost: incomplete, fuel: fuel).rates.total)
    }
}
