import XCTest
@testable import GPUMonitor

final class BatteryRecorderTests: XCTestCase {

    func testTicksFallOnIntervalMultiples() {
        XCTAssertEqual(BatteryRecorder.nextTick(after: 1_000.2, interval: 1), 1_001)
        XCTAssertEqual(BatteryRecorder.nextTick(after: 1_000.2, interval: 5), 1_005)
        XCTAssertEqual(BatteryRecorder.nextTick(after: 1_000.2, interval: 60), 1_020)
        XCTAssertEqual(BatteryRecorder.nextTick(after: 1_005, interval: 5), 1_010, "strictly after")
        XCTAssertEqual(BatteryRecorder.nextTick(after: 1_004.999, interval: 5), 1_005)
    }

    func testIntervalOptions() {
        XCTAssertEqual(BatteryRecorder.intervals, [1, 5, 10, 30, 60])
        XCTAssertTrue(BatteryRecorder.intervals.contains(BatteryRecorder.defaultInterval))
    }

    func testRangeOptions() {
        XCTAssertEqual(BatteryRange.allCases.map(\.label), ["5m", "15m", "1h", "4h", "24h", "2d", "4d", "10d"])
        XCTAssertEqual(BatteryRange.d10.seconds, 10 * 86_400)
        // History must outlive the longest range.
        XCTAssertGreaterThan(Double(BatteryStore().retentionDays * 86_400), BatteryRange.d10.seconds)
    }

    func testRangeAxis() {
        for r in BatteryRange.allCases {
            let steps = r.seconds / r.gridStep
            XCTAssertEqual(steps, steps.rounded(), "\(r.label): grid step divides the range")
            XCTAssertTrue((3...6).contains(Int(steps)), "\(r.label): \(steps) grid steps")
        }
        func labels(_ r: BatteryRange) -> [String] {
            stride(from: r.rawValue, through: 0, by: -Int(r.gridStep)).map { r.axisLabel(secondsAgo: $0) }
        }
        XCTAssertEqual(labels(.m5), ["−5 min", "−4 min", "−3 min", "−2 min", "−1 min", "now"])
        XCTAssertEqual(labels(.h1), ["−1 h", "−45 min", "−30 min", "−15 min", "now"])
        XCTAssertEqual(labels(.d2), ["−48 h", "−36 h", "−24 h", "−12 h", "now"])
        XCTAssertEqual(labels(.d10), ["−10 d", "−8 d", "−6 d", "−4 d", "−2 d", "now"])
    }
}
