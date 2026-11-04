import XCTest
@testable import GPUMonitor

final class BatteryBucketsTests: XCTestCase {

    let t0 = Double(20_000 * 86_400)

    func add(_ b: inout BatteryBuckets, _ t: Double, interval: Double = 1,
             charge: Float = 50, system: Float = 10, battery: Float = -10, ac: Bool? = nil,
             mode: PowerMode? = nil) {
        b.add(time: t0 + t, interval: interval, charge: charge, system: system, battery: battery, acPower: ac,
              mode: mode)
    }

    /// Field by field, with NaN equal to NaN.
    func assertSame(_ a: Summary, _ b: Summary, file: StaticString = #filePath, line: UInt = #line) {
        func same<T: FloatingPoint>(_ x: T, _ y: T) -> Bool { x == y || (x.isNaN && y.isNaN) }
        let fields: [(String, Bool)] = [
            ("min", same(a.min, b.min)), ("max", same(a.max, b.max)), ("mean", same(a.mean, b.mean)),
            ("median", same(a.median, b.median)), ("p2_5", same(a.p2_5, b.p2_5)), ("p25", same(a.p25, b.p25)),
            ("p75", same(a.p75, b.p75)), ("p97_5", same(a.p97_5, b.p97_5)),
        ]
        for (name, ok) in fields where !ok { XCTFail("\(name) differs: \(a) vs \(b)", file: file, line: line) }
    }

    func testMinMax() {
        var m = MinMax()
        XCTAssertTrue(m.isEmpty)
        m.add(.nan)
        XCTAssertTrue(m.isEmpty, "missing values are ignored")
        m.add(3); m.add(-1); m.add(2)
        XCTAssertEqual(m, MinMax(min: -1, max: 3))
    }

    func testOneBucketPerColumn() {
        XCTAssertEqual(BatteryBuckets(range: BatteryRange.m5.seconds, columns: 100).bucketSeconds, 3)
        XCTAssertEqual(BatteryBuckets(range: BatteryRange.d10.seconds, columns: 1_000).bucketSeconds, 864)
    }

    func testSummary() {
        let values: [Float] = (0...40).map(Float.init) + [.nan]
        let s = Summary(values.shuffled())
        XCTAssertEqual(s.min, 0)
        XCTAssertEqual(s.max, 40)
        XCTAssertEqual(s.mean, 20, "missing values are ignored")
        XCTAssertEqual(s.median, 20)
        XCTAssertEqual(s.p2_5, 1, "2.5% of the 40 gaps between ranks")
        XCTAssertEqual(s.p25, 10)
        XCTAssertEqual(s.p75, 30)
        XCTAssertEqual(s.p97_5, 39)
        XCTAssertTrue(Summary([.nan]).isEmpty)
        XCTAssertTrue(Summary([]).isEmpty)
    }

    func testQuantileInterpolates() {
        XCTAssertEqual(Summary.quantile([0, 10], 0.25), 2.5)
        XCTAssertEqual(Summary.quantile([7], 0.975), 7)
        XCTAssertEqual(Summary.quantile([1, 2, 3], 1), 3)
    }

    /// The bug: a series swinging between two levels drew one line along each.
    /// Every style now draws one value or one band per column.
    func testVolatileSeriesGivesOneValuePerColumn() {
        var b = BatteryBuckets(range: 864, columns: 2)  // 432 s buckets
        for i in 0..<864 { add(&b, Double(i), system: i % 2 == 0 ? 10 : 90) }
        let cols = b.columns(\.system, width: 2, windowStart: t0, range: 864)
        XCTAssertEqual(cols.count, 1)
        XCTAssertEqual(cols[0].map(\.x), [0.5, 1.5])
        let s = cols[0][0].summary
        XCTAssertEqual(ChartStyle.average.line(s), 50)
        XCTAssertTrue(ChartStyle.average.bands(s).isEmpty)
        XCTAssertNil(ChartStyle.minMax.line(s))
        XCTAssertEqual(ChartStyle.minMax.bands(s).map { [$0.low, $0.high] }, [[10, 90]])
        XCTAssertEqual(ChartStyle.averageBand.line(s), 50)
        XCTAssertEqual(ChartStyle.averageBand.bands(s).map { [$0.low, $0.high] }, [[10, 90]])
        XCTAssertEqual(ChartStyle.quartiles.line(s), 50, "median halfway between the two levels")
        XCTAssertEqual(ChartStyle.quartiles.bands(s).map { [$0.low, $0.high] }, [[10, 90], [10, 90]])
    }

    func testBandsAgreeOnTypicalValuesButNotOnOutliers() {
        var b = BatteryBuckets(range: 1_000, columns: 1)
        for i in 0..<1_000 { add(&b, Double(i), system: i == 500 ? 90 : 10) }
        let s = b.runs[0][0].system
        XCTAssertEqual(s.max, 90, "min–max keeps the spike")
        XCTAssertEqual(s.p97_5, 10, "the 95% band leaves a single spike out")
        XCTAssertEqual(s.mean, 10.08, accuracy: 0.001)
        XCTAssertEqual(s.median, 10)
    }

    func testNewestBucketUpdatesWithEveryTick() {
        var b = BatteryBuckets(range: 100, columns: 1)
        add(&b, 0, system: 10)
        XCTAssertEqual(b.runs[0][0].system.mean, 10)
        add(&b, 1, system: 30)
        XCTAssertEqual(b.runs[0][0].system.mean, 20)
        XCTAssertEqual(b.runs[0][0].system.max, 30)
    }

    /// Live ticks one at a time must end up exactly where loading the same samples from disk does.
    func testLiveTicksMatchBulkLoad() {
        let n = 200
        let values = (0..<n).map { Float(($0 * 37) % 23) }
        let seg = BatterySegment(start: Date(timeIntervalSince1970: t0), interval: 1,
                                 chargePct: values, systemPowerW: values.reversed(),
                                 batteryPowerW: values.map { -$0 })
        var bulk = BatteryBuckets(range: 200, columns: 30)
        bulk.add(seg)
        var live = BatteryBuckets(range: 200, columns: 30)
        for i in 0..<n { add(&live, Double(i), charge: seg.chargePct[i], system: seg.systemPowerW[i], battery: seg.batteryPowerW[i]) }

        XCTAssertEqual(bulk.runs.map { $0.map(\.index) }, live.runs.map { $0.map(\.index) })
        for (a, b) in zip(bulk.runs[0], live.runs[0]) {
            assertSame(a.charge, b.charge)
            assertSame(a.system, b.system)
            assertSame(a.battery, b.battery)
        }
    }

    func testGapStartsNewRun() {
        var b = BatteryBuckets(range: 3600, columns: 3600)
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
        var b = BatteryBuckets(range: 300, columns: 300)
        add(&b, 10, charge: 10)
        add(&b, 10, charge: 99)
        add(&b, 5, charge: 99)
        XCTAssertEqual(b.runs.flatMap { $0 }.map(\.charge.max), [10])
    }

    func testMissingSeriesValuesAreLeftOut() {
        var b = BatteryBuckets(range: 300, columns: 300)
        add(&b, 0, system: .nan)
        add(&b, 1, system: .nan)
        XCTAssertTrue(b.columns(\.system, width: 300, windowStart: t0, range: 300).isEmpty)
        XCTAssertEqual(b.columns(\.charge, width: 300, windowStart: t0, range: 300).first?.count, 2)
    }

    func testTrim() {
        var b = BatteryBuckets(range: 100, columns: 2_000)  // 0.05 s buckets
        for i in 0..<10 { add(&b, Double(i)) }
        for i in 20..<30 { add(&b, Double(i)) }
        XCTAssertEqual(b.runs.map(\.count), [10, 10])

        b.trim(before: t0 + 5)
        XCTAssertEqual(b.runs.map(\.count), [5, 10])
        b.trim(before: t0 + 25)
        XCTAssertEqual(b.runs.map(\.count), [5], "whole runs before the window are dropped")
        b.trim(before: t0 + 1000)
        XCTAssertTrue(b.runs.isEmpty)
        add(&b, 30)
        XCTAssertEqual(b.runs.map(\.count), [1], "adding after everything was trimmed starts a new run")
    }

    func testColumnsMapTimeToPixels() {
        var b = BatteryBuckets(range: 300, columns: 100)  // 3 s buckets
        for i in 0..<300 { add(&b, Double(i) + 0.5, charge: Float(i)) }
        add(&b, 300, charge: 300)
        let cols = b.columns(\.charge, width: 100, windowStart: t0, range: 300)

        XCTAssertEqual(cols.count, 1)
        XCTAssertEqual(cols[0].map(\.x), (0..<100).map { Double($0) + 0.5 } + [99.5],
                       "one bucket per pixel, the newest clamped to the right edge")
        XCTAssertEqual(cols[0][0].summary.min, 0)
        XCTAssertEqual(cols[0][0].summary.max, 2)
        XCTAssertEqual(cols[0][0].summary.mean, 1)
        XCTAssertEqual(cols[0][100].summary.mean, 300)
    }

    func testPowerSpans() {
        var b = BatteryBuckets(range: 3_600, columns: 600)
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
        var b = BatteryBuckets(range: 3_600, columns: 600)
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
        var b = BatteryBuckets(range: 300, columns: 300)
        b.add(seg)
        XCTAssertEqual(b.powerSpans, [BatteryBuckets.PowerSpan(ac: true, start: t0, end: t0 + 10)],
                       "a missing entry is unknown and ends the span")
    }

    func testModeSpans() {
        var b = BatteryBuckets(range: 3_600, columns: 600)
        for i in 0..<10 { add(&b, Double(i), mode: nil) }                    // 0–9 s: unknown (pre-v3 history)
        for i in 10..<20 { add(&b, Double(i), ac: i < 15, mode: .low) }       // 10–19 s: Low Power, AC flips
        for i in 20..<30 { add(&b, Double(i), mode: .high) }                 // 20–29 s: High Power
        for i in 100..<105 { add(&b, Double(i), mode: .high) }               // after a gap: a new span
        add(&b, 105, mode: nil)                                               // unknown ends it

        typealias S = BatteryBuckets.ModeSpan
        XCTAssertEqual(b.modeSpans, [
            S(mode: .low, start: t0 + 10, end: t0 + 20),   // held until the next mode; AC changes don't split it
            S(mode: .high, start: t0 + 20, end: t0 + 29),  // ends at the last sample before the gap
            S(mode: .high, start: t0 + 100, end: t0 + 105),
        ])
        add(&b, 106, mode: .automatic)
        XCTAssertEqual(b.modeSpans.last, S(mode: .automatic, start: t0 + 106, end: t0 + 106),
                       "starts fresh after unknown")
    }

    func testModeSpansTrim() {
        var b = BatteryBuckets(range: 3_600, columns: 600)
        for i in 0..<10 { add(&b, Double(i), mode: .automatic) }
        for i in 10..<20 { add(&b, Double(i), mode: .low) }
        b.trim(before: t0 + 15)
        XCTAssertEqual(b.modeSpans, [BatteryBuckets.ModeSpan(mode: .low, start: t0 + 15, end: t0 + 19)],
                       "older spans dropped, the straddling one cut at the window edge")
        add(&b, 20, mode: .low)
        XCTAssertEqual(b.modeSpans.last?.end, t0 + 20, "still extended")
        b.trim(before: t0 + 1_000)
        XCTAssertTrue(b.modeSpans.isEmpty)
        add(&b, 1_001, mode: .high)
        XCTAssertEqual(b.modeSpans.count, 1)
    }

    func testModeSpanFromSegment() {
        let seg = BatterySegment(start: Date(timeIntervalSince1970: t0), interval: 5,
                                 chargePct: [1, 2, 3], systemPowerW: [4, 5, 6], batteryPowerW: [-1, -2, -3],
                                 powerMode: [.low, .low])
        var b = BatteryBuckets(range: 300, columns: 300)
        b.add(seg)
        XCTAssertEqual(b.modeSpans, [BatteryBuckets.ModeSpan(mode: .low, start: t0, end: t0 + 10)],
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
        var b = BatteryBuckets(range: 300, columns: 300)
        b.add(seg)
        XCTAssertEqual(b.runs.map(\.count), [3])
        XCTAssertEqual(b.runs[0][0].system.mean, 4)
        XCTAssertTrue(b.runs[0][1].system.isEmpty, "missing value")
        XCTAssertEqual(b.runs[0][2].system.mean, 6)
        XCTAssertEqual(b.lastTime, t0 + 10)
    }

    /// The load path for the largest range: 10 days at 1 s. Runs off the main thread in the app.
    func testTenDaysAtOneSecondReduces() {
        let n = 864_000
        let seg = BatterySegment(start: Date(timeIntervalSince1970: t0), interval: 1,
                                 chargePct: .init(repeating: 50, count: n),
                                 systemPowerW: (0..<n).map { Float($0 % 97) },
                                 batteryPowerW: .init(repeating: -10, count: n))
        var b = BatteryBuckets(range: BatteryRange.d10.seconds, columns: 800)
        b.add(seg)
        XCTAssertEqual(b.runs.map(\.count), [800])
        XCTAssertEqual(b.columns(\.battery, width: 800, windowStart: t0, range: BatteryRange.d10.seconds).first?.count, 800)
    }

    func testExtentFollowsStyle() {
        var b = BatteryBuckets(range: 300, columns: 1)
        XCTAssertTrue(b.extent(\.battery, style: .minMax).isEmpty)
        add(&b, 0, battery: -40)
        for i in 1...38 { add(&b, Double(i), battery: 10) }
        add(&b, 39, battery: .nan)
        add(&b, 40, battery: 30)
        // 40 values: −40, 38 × 10, 30. Mean 370 / 40.
        XCTAssertEqual(b.extent(\.battery, style: .minMax), MinMax(min: -40, max: 30))
        XCTAssertEqual(b.extent(\.battery, style: .average), MinMax(min: 9.25, max: 9.25))
        let band = b.extent(\.battery, style: .averageBand)
        XCTAssertGreaterThan(band.min, -40, "the bottom 2.5% are outside the band")
        XCTAssertLessThan(band.max, 30)
        XCTAssertEqual(b.extent(\.battery, style: .quartiles), MinMax(min: -40, max: 30), "the faint band reaches the extremes")
    }
}
