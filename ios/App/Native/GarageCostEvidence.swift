import Foundation

/// Legacy overview output can substitute zero for a missing fuel model. Preserve unknown evidence.
struct GarageCostEvidence {
    let rates: RunningCostRates

    init(cost: RunningCost?, fuel: FuelTotals?) {
        let fuelRate = fuel?.modelCostPerKM.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let service = cost?.perKM?.service.flatMap { $0.isFinite ? $0 : nil }
        let other = cost?.perKM?.other.flatMap { $0.isFinite ? $0 : nil }
        let total: Double?
        if let fuelRate, let service, let other { total = fuelRate + service + other }
        else { total = nil }
        rates = RunningCostRates(fuel: fuelRate, service: service, other: other, total: total)
    }
}
