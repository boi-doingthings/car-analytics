import XCTest
@testable import I20Logbook

final class FuelScenarioTests: XCTestCase {
    private func coefficients(_ text: String = #"{"city_l100":8,"hwy_l100":5,"idle_lph":0.8}"#) throws -> FuelCoefficients {
        try JSONDecoder().decode(FuelCoefficients.self, from: Data(text.utf8))
    }

    func test_hypotheticalMixUsesDistanceAndHoursWithExplicitUnits() throws {
        let scenario = FuelScenario(distanceKM: 200, cityShare: 0.6, idleHours: 1.5, pricePerLitre: 100)
        let estimate = try XCTUnwrap(scenario.estimate(using: try coefficients()))
        XCTAssertEqual(estimate.movingLitres, 13.6, accuracy: 1e-9)
        XCTAssertEqual(estimate.idleLitres, 1.2, accuracy: 1e-9)
        XCTAssertEqual(estimate.cost, 1480, accuracy: 1e-8)
    }

    func test_missingOrNonPhysicalCoefficientsNeverSubstituteDefaults() throws {
        let scenario = FuelScenario(distanceKM: 100, cityShare: 0.5, idleHours: 1, pricePerLitre: 100)
        XCTAssertNil(scenario.estimate(using: nil))
        XCTAssertNil(scenario.estimate(using: try coefficients(#"{"city_l100":8,"hwy_l100":null,"idle_lph":0.8}"#)))
        XCTAssertNil(scenario.estimate(using: try coefficients(#"{"city_l100":8,"hwy_l100":5,"idle_lph":-0.1}"#)))
    }

    func test_unknownAndInvalidInputsCannotBecomeAPlausibleResult() throws {
        let coef = try coefficients()
        for input in [
            FuelScenario(distanceKM: -.infinity, cityShare: 0.5, idleHours: 1, pricePerLitre: 100),
            FuelScenario(distanceKM: 200, cityShare: 1.2, idleHours: 1, pricePerLitre: 100),
            FuelScenario(distanceKM: 200, cityShare: 0.5, idleHours: -1, pricePerLitre: 100),
            FuelScenario(distanceKM: 200, cityShare: 0.5, idleHours: 1, pricePerLitre: 0)
        ] { XCTAssertNil(input.estimate(using: coef)) }
        let noDriving = FuelScenario(distanceKM: 0, cityShare: 0.5, idleHours: 0, pricePerLitre: 100)
        XCTAssertEqual(noDriving.estimate(using: coef)?.cost, 0)
    }
}
