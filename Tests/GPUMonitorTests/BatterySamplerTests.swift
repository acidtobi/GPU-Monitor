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

    func testPowerModeDecoding() {
        XCTAssertEqual(PowerMode(settings: ["LowPowerMode": 0]), .automatic)
        XCTAssertEqual(PowerMode(settings: ["LowPowerMode": 1]), .low)
        XCTAssertEqual(PowerMode(settings: ["LowPowerMode": 2, "HighPowerMode": 0]), .high)
        XCTAssertEqual(PowerMode(settings: ["LowPowerMode": 0, "HighPowerMode": 1]), .high, "macOS 12 key")
        XCTAssertNil(PowerMode(settings: ["LowPowerMode": 7]))
        XCTAssertNil(PowerMode(settings: [:]))
    }

    /// The live mode must agree with Foundation's Low Power flag.
    func testLivePowerMode() throws {
        guard let mode = PowerMode.current() else { throw XCTSkip("powerd publishes no Energy Mode") }
        XCTAssertEqual(mode == .low, ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    func testLiveSampleUsesRealLevel() throws {
        guard let reading = BatterySampler().sample() else { throw XCTSkip("no battery") }
        XCTAssertTrue((0...100).contains(reading.sample.chargePct))
        XCTAssertNotNil(reading.sample.systemPowerW)
        XCTAssertNotNil(reading.sample.batteryPowerW)
    }
}
