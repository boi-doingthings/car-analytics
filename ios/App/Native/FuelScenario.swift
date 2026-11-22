import Foundation

/// A hypothetical operating mix, never an observed or promised saving.
struct FuelScenario: Sendable {
    var distanceKM: Double
    var cityShare: Double
    var idleHours: Double
    var pricePerLitre: Double

    struct Estimate: Equatable, Sendable {
        let movingLitres: Double
        let idleLitres: Double
        var totalLitres: Double { movingLitres + idleLitres }
        let pricePerLitre: Double
        var cost: Double { totalLitres * pricePerLitre }
    }

    func estimate(using coefficients: FuelCoefficients?) -> Estimate? {
        guard [distanceKM, cityShare, idleHours, pricePerLitre].allSatisfy(\.isFinite),
              distanceKM >= 0, (0...1).contains(cityShare), idleHours >= 0, pricePerLitre > 0,
              let coefficients, let city = coefficients.cityL100,
              let highway = coefficients.highwayL100, let idle = coefficients.idleLPH,
              [city, highway, idle].allSatisfy(\.isFinite), city > 0, highway > 0, idle >= 0 else { return nil }
        let moving = distanceKM / 100 * (cityShare * city + (1 - cityShare) * highway)
        let standing = idleHours * idle
        let result = Estimate(movingLitres: moving, idleLitres: standing, pricePerLitre: pricePerLitre)
        guard result.totalLitres.isFinite, result.cost.isFinite else { return nil }
        return result
    }
}
