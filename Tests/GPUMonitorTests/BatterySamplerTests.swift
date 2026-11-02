import XCTest
@testable import GPUMonitor

final class BatterySamplerTests: XCTestCase {

    func testFourCC() {
        XCTAssertEqual(SMC.fourCC("PSTR"), 0x5053_5452)
        XCTAssertEqual(SMC.floatType, 0x666C_7420)
    }

    /// Reads the real SMC. Skipped on Macs without the Apple Silicon power keys.
    func testLiveSMCPowerKeys() throws {
        let smc = try XCTUnwrap(SMC())
        guard let system = smc.float("PSTR") else { throw XCTSkip("no PSTR key on this Mac") }
        XCTAssertGreaterThan(system, 0)
        XCTAssertLessThan(system, 500)
        XCTAssertNil(smc.float("B0AV"), "integer keys are not read as floats")
        XCTAssertNil(smc.float("ZZZZ"), "missing key")
    }

    func testLiveSampleUsesRealLevel() throws {
        guard let reading = BatterySampler().sample() else { throw XCTSkip("no battery") }
        XCTAssertTrue((0...100).contains(reading.sample.chargePct))
        XCTAssertNotNil(reading.sample.systemPowerW)
        XCTAssertNotNil(reading.sample.batteryPowerW)
    }
}
