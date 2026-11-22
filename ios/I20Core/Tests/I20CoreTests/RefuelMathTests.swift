import Testing
@testable import I20Core

@Suite struct RefuelMathTests {
    @Test func derivesLitres() throws {
        let r = try RefuelMath.complete(litres: nil, amount: 3535.67, rate: 106.40).get()
        #expect(abs(r.litres - 33.23) < 0.005 && r.amount == 3535.67 && r.rate == 106.40)
    }
    @Test func derivesAmount() throws {
        let r = try RefuelMath.complete(litres: 33.23, amount: nil, rate: 106.40).get()
        #expect(abs(r.amount - 3535.67) < 0.01)
    }
    @Test func derivesRate() throws {
        let r = try RefuelMath.complete(litres: 33.23, amount: 3535.67, rate: nil).get()
        #expect(abs(r.rate - 106.40) < 0.01)
    }
    @Test func consistentTripleAccepted() throws {
        let r = try RefuelMath.complete(litres: 33.23, amount: 3535.67, rate: 106.4).get()
        #expect(r.litres == 33.23)
    }
    @Test func inconsistentTripleRejected() {
        #expect(throws: RefuelInputError.inconsistent) { try RefuelMath.complete(litres: 33.23, amount: 3600, rate: 106.4).get() }
    }
    @Test func nonPositiveRejected() {
        #expect(throws: RefuelInputError.nonPositive) { try RefuelMath.complete(litres: 0, amount: 100, rate: 10).get() }
        #expect(throws: RefuelInputError.nonPositive) { try RefuelMath.complete(litres: nil, amount: -5, rate: 10).get() }
        #expect(throws: RefuelInputError.nonPositive) { try RefuelMath.complete(litres: 5, amount: 50, rate: -10).get() }
        #expect(throws: RefuelInputError.nonPositive) { try RefuelMath.complete(litres: nil, amount: .nan, rate: 10).get() }
    }
    @Test func needTwo() {
        #expect(throws: RefuelInputError.needTwo) { try RefuelMath.complete(litres: 5, amount: nil, rate: nil).get() }
        #expect(throws: RefuelInputError.needTwo) { try RefuelMath.complete(litres: nil, amount: nil, rate: nil).get() }
    }
    @Test func parse() {
        #expect(RefuelMath.parse("₹3,535.67") == 3535.67)
        #expect(RefuelMath.parse("1,234.5") == 1234.5)
        #expect(RefuelMath.parse("33,23") == 33.23)
        #expect(RefuelMath.parse("33,2") == 33.2)
        #expect(RefuelMath.parse("1,234") == 1234)
        #expect(RefuelMath.parse("1,23,456") == 123456)
        #expect(RefuelMath.parse(" 106.4 ") == 106.4)
        #expect(RefuelMath.parse("12") == 12)
        #expect(RefuelMath.parse("-5") == -5)
        for bad in ["", "abc", "nan", "inf", "1e5", "0x10", "1.2.3", "₹"] { #expect(RefuelMath.parse(bad) == nil, "\(bad)") }
    }
    @Test func odometer() {
        #expect(odometerWarning(11000, previous: 11044) != nil)
        #expect(odometerWarning(11044, previous: 11044) == nil)
        #expect(odometerWarning(12000, previous: 11044) == nil)
        #expect(odometerWarning(100, previous: nil) == nil)
    }
}
