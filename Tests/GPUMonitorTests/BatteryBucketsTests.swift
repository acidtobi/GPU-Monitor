import XCTest
@testable import GPUMonitor

final class BatteryBucketsTests: XCTestCase {

    let t0 = Double(20_000 * 86_400)

    func add(_ b: inout BatteryBuckets, _ t: Double, interval: Double = 1,
             charge: Float = 50, system: Float = 10, battery: Float = -10, ac: Bool? = nil) {
        b.add(time: t0 + t, interval: interval, charge: charge, system: system, battery: battery, acPower: ac)
    }

    func testMinMax() {
        var m = MinMax()
        XCTAssertTrue(m.isEmpty)
        m.add(.nan)
        XCTAssertTrue(m.isEmpty, "missing values are ignored")
        m.add(3); m.add(-1); m.add(2)
        XCTAssertEqual(m, MinMax(min: -1, max: 3))
    }

    func testBucketSizeFollowsRange() {
        XCTAssertEqual(BatteryBuckets(range: BatteryRange.m5.seconds).bucketSeconds, 0.15)
        XCTAssertEqual(BatteryBuckets(range: BatteryRange.d10.seconds).bucketSeconds, 432)
    }

    func testSpikeSurvivesDownsampling() {
        var b = BatteryBuckets(range: BatteryRange.d10.seconds)  // 432 s buckets
        for i in 0..<864 { add(&b, Double(i), system: i == 500 ? 90 : 10) }
        XCTAssertEqual(b.runs.count, 1)
        XCTAssertEqual(b.runs[0].count, 2, "864 s of 1 s samples in two 432 s buckets")

        let cols = b.columns(\.system, width: 1, windowStart: t0, range: 864)
        XCTAssertEqual(cols, [[BatteryBuckets.Column(x: 0, min: 10, max: 90)]])
    }

    func testGapStartsNewRun() {
        var b = BatteryBuckets(range: 3600)
        add(&b, 0); add(&b, 1); add(&b, 2)
        add(&b, 3.4)                          // within 1.5 × interval: same run
        add(&b, 10)                           // gap
        add(&b, 15, interval: 5)              // interval change, 5 s later: connected
        add(&b, 22.5, interval: 5)            // exactly 1.5 × 5: connected
        add(&b, 40, interval: 5)              // gap
        XCTAssertEqual(b.runs.count, 3)
        XCTAssertEqual(b.lastTime, t0 + 40)
    }

    func testOutOfOrderAndDuplicateSamplesIgnored() {
        var b = BatteryBuckets(range: 300)
        add(&b, 10, charge: 10)
        add(&b, 10, charge: 99)
        add(&b, 5, charge: 99)
        XCTAssertEqual(b.runs.flatMap { $0 }.map(\.charge), [MinMax(min: 10, max: 10)])
    }

    func testMissingSeriesValuesAreLeftOut() {
        var b = BatteryBuckets(range: 300)
        add(&b, 0, system: .nan)
        add(&b, 1, system: .nan)
        XCTAssertTrue(b.columns(\.system, width: 100, windowStart: t0, range: 300).isEmpty)
        XCTAssertEqual(b.columns(\.charge, width: 100, windowStart: t0, range: 300).first?.count, 1)
    }

    func testTrim() {
        var b = BatteryBuckets(range: 100)  // 0.05 s buckets
        for i in 0..<10 { add(&b, Double(i)) }
        for i in 20..<30 { add(&b, Double(i)) }
        XCTAssertEqual(b.runs.map(\.count), [10, 10])

        b.trim(before: t0 + 5)
        XCTAssertEqual(b.runs.map(\.count), [5, 10])
        b.trim(before: t0 + 25)
        XCTAssertEqual(b.runs.map(\.count), [5], "whole runs before the window are dropped")
        b.trim(before: t0 + 1000)
        XCTAssertTrue(b.runs.isEmpty)
    }

    func testColumnsMapTimeToPixels() {
        var b = BatteryBuckets(range: 300)
        // Half-second offsets keep samples clear of the 3 s column boundaries.
        for i in 0..<300 { add(&b, Double(i) + 0.5, charge: Float(i)) }
        add(&b, 300, charge: 300)
        let cols = b.columns(\.charge, width: 100, windowStart: t0, range: 300)

        XCTAssertEqual(cols.count, 1)
        XCTAssertEqual(cols[0].map(\.x), Array(0..<100), "one column per pixel, newest clamped to the right edge")
        XCTAssertEqual(cols[0][0], BatteryBuckets.Column(x: 0, min: 0, max: 2))
        XCTAssertEqual(cols[0][99], BatteryBuckets.Column(x: 99, min: 297, max: 300))
    }

    func testPowerSpans() {
        var b = BatteryBuckets(range: 3_600)
        for i in 0..<10 { add(&b, Double(i), ac: nil) }              // 0–9 s: unknown (v1 history)
        for i in 10..<20 { add(&b, Double(i), ac: false) }           // 10–19 s: battery
        for i in 20..<30 { add(&b, Double(i), ac: true) }            // 20–29 s: AC
        for i in 100..<105 { add(&b, Double(i), ac: true) }          // after a gap: a new AC span
        add(&b, 105, ac: nil)                                         // unknown ends it

        typealias S = BatteryBuckets.PowerSpan
        XCTAssertEqual(b.powerSpans, [
            S(ac: false, start: t0 + 10, end: t0 + 20),  // held until the AC sample, so spans meet
            S(ac: true, start: t0 + 20, end: t0 + 29),   // ends at the last sample before the gap
            S(ac: true, start: t0 + 100, end: t0 + 105),
        ])
        add(&b, 106, ac: true)
        XCTAssertEqual(b.powerSpans.last, S(ac: true, start: t0 + 106, end: t0 + 106), "starts fresh after unknown")
    }

    func testPowerSpansTrim() {
        var b = BatteryBuckets(range: 3_600)
        for i in 0..<10 { add(&b, Double(i), ac: false) }
        for i in 10..<20 { add(&b, Double(i), ac: true) }
        b.trim(before: t0 + 15)
        XCTAssertEqual(b.powerSpans, [BatteryBuckets.PowerSpan(ac: true, start: t0 + 15, end: t0 + 19)],
                       "older spans dropped, the straddling one cut at the window edge")
        add(&b, 20, ac: true)
        XCTAssertEqual(b.powerSpans.last?.end, t0 + 20, "still extended")
        b.trim(before: t0 + 1_000)
        XCTAssertTrue(b.powerSpans.isEmpty)
        add(&b, 1_001, ac: false)
        XCTAssertEqual(b.powerSpans.count, 1)
    }

    func testPowerSpanFromSegment() {
        let seg = BatterySegment(start: Date(timeIntervalSince1970: t0), interval: 5,
                                 chargePct: [1, 2, 3], systemPowerW: [4, 5, 6], batteryPowerW: [-1, -2, -3],
                                 acPower: [true, true])
        var b = BatteryBuckets(range: 300)
        b.add(seg)
        XCTAssertEqual(b.powerSpans, [BatteryBuckets.PowerSpan(ac: true, start: t0, end: t0 + 10)],
                       "a missing entry is unknown and ends the span")
    }

    func testDurationLabel() {
        func label(_ s: TimeInterval) -> String { BatteryBuckets.PowerSpan(ac: true, start: 0, end: s).durationLabel }
        XCTAssertEqual(label(45), "45s")
        XCTAssertEqual(label(12 * 60 + 30), "12m")
        XCTAssertEqual(label(5 * 3_600 + 12 * 60), "5h 12m")
        XCTAssertEqual(label(3_600), "1h 0m")
        XCTAssertEqual(label(2 * 86_400 + 3 * 3_600 + 59 * 60), "2d 3h")
    }

    func testAddSegment() {
        let seg = BatterySegment(start: Date(timeIntervalSince1970: t0), interval: 5,
                                 chargePct: [1, 2, 3], systemPowerW: [4, .nan, 6], batteryPowerW: [-1, -2, -3])
        var b = BatteryBuckets(range: 300)
        b.add(seg)
        XCTAssertEqual(b.runs.map(\.count), [3])
        XCTAssertEqual(b.runs[0][0].system, MinMax(min: 4, max: 4))
        XCTAssertTrue(b.runs[0][1].system.isEmpty, "missing value")
        XCTAssertEqual(b.runs[0][2].system, MinMax(min: 6, max: 6))
        XCTAssertEqual(b.lastTime, t0 + 10)
    }

    /// The load path for the largest range: 10 days at 1 s. Runs off the main thread in the app.
    func testTenDaysAtOneSecondReduces() {
        let n = 864_000
        let seg = BatterySegment(start: Date(timeIntervalSince1970: t0), interval: 1,
                                 chargePct: .init(repeating: 50, count: n),
                                 systemPowerW: .init(repeating: 10, count: n),
                                 batteryPowerW: .init(repeating: -10, count: n))
        var b = BatteryBuckets(range: BatteryRange.d10.seconds)
        b.add(seg)
        XCTAssertEqual(b.runs.map(\.count), [2_000])
        XCTAssertEqual(b.columns(\.battery, width: 800, windowStart: t0, range: BatteryRange.d10.seconds).first?.count, 800)
    }

    func testExtent() {
        var b = BatteryBuckets(range: 300)
        XCTAssertTrue(b.extent(\.battery).isEmpty)
        add(&b, 0, battery: -12)
        add(&b, 1, battery: .nan)
        add(&b, 10, battery: 30)  // separate run
        XCTAssertEqual(b.extent(\.battery), MinMax(min: -12, max: 30))
    }
}
