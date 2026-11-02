import XCTest
@testable import GPUMonitor

final class BatteryStoreTests: XCTestCase {

    /// 2024-10-04 00:00 UTC, day 20 000.
    let day0 = Double(20_000 * 86_400)
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("BatteryStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Helpers

    func sample(_ t: Double, pct: Double = 50, sys: Double? = 12.34, bat: Double? = -5.67) -> BatterySample {
        BatterySample(timestamp: Date(timeIntervalSince1970: t), chargePct: pct, systemPowerW: sys, batteryPowerW: bat)
    }

    func makeStore() -> BatteryStore { BatteryStore(directory: dir, flushInterval: 0) }

    func read(_ from: Double, _ to: Double) -> [BatterySegment] {
        BatteryStore.read(from: Date(timeIntervalSince1970: from), to: Date(timeIntervalSince1970: to), directory: dir)
    }

    func file(day: Int) -> URL { BatteryStore.fileURL(day: day, in: dir) }

    // MARK: - Format

    func testRoundTripAndQuantization() throws {
        let store = makeStore()
        try store.append(sample(day0 + 100, pct: 87.654, sys: 18.613, bat: -12.3456), interval: 1)
        try store.append(sample(day0 + 101.2, pct: 100, sys: nil, bat: 400), interval: 1)  // jitter, missing, clamp
        try store.append(sample(day0 + 102, pct: 0, sys: -400, bat: .nan), interval: 1)
        try store.close()

        let segs = read(day0, day0 + 1000)
        XCTAssertEqual(segs.count, 1)
        let g = try XCTUnwrap(segs.first)
        XCTAssertEqual(g.count, 3)
        XCTAssertEqual(g.start.timeIntervalSince1970, day0 + 100)
        XCTAssertEqual(g.interval, 1)
        XCTAssertEqual(g.chargePct[0], 87.65, accuracy: 0.006, "0.01 % resolution")
        XCTAssertEqual(g.systemPowerW[0], 18.61, accuracy: 0.006, "10 mW resolution")
        XCTAssertEqual(g.batteryPowerW[0], -12.35, accuracy: 0.006)
        XCTAssertTrue(g.systemPowerW[1].isNaN, "nil → missing → NaN")
        XCTAssertEqual(g.batteryPowerW[1], 327.67, accuracy: 0.001, "clamped high")
        XCTAssertEqual(g.chargePct[2], 0)
        XCTAssertEqual(g.systemPowerW[2], -327.67, accuracy: 0.001, "clamped low without hitting the sentinel")
        XCTAssertTrue(g.batteryPowerW[2].isNaN, "NaN → missing")

        let size = try FileManager.default.attributesOfItem(atPath: file(day: 20_000).path)[.size] as? Int
        XCTAssertEqual(size, BatteryStore.fileHeaderSize + BatteryStore.segmentHeaderSize + 3 * BatteryStore.sampleSize)
    }

    func testEncodingLimits() {
        XCTAssertEqual(BatteryStore.encodePct(-5), 0)
        XCTAssertEqual(BatteryStore.encodePct(150), 10_000)
        XCTAssertEqual(BatteryStore.encodePct(.nan), 0)
        XCTAssertLessThan(BatteryStore.encodePct(100), BatteryStore.segmentMarker, "a sample never looks like a segment header")
        XCTAssertEqual(BatteryStore.encodePower(nil), BatteryStore.missingPower)
        XCTAssertEqual(BatteryStore.encodePower(.infinity), BatteryStore.missingPower)
        XCTAssertEqual(BatteryStore.encodePower(-1e9), BatteryStore.missingPower + 1)
        XCTAssertEqual(BatteryStore.encodePower(1e9), Int16.max)
        XCTAssertEqual(BatteryStore.encodePower(-0.004), 0)
        XCTAssertTrue(BatteryStore.decodePower(BatteryStore.missingPower).isNaN)
    }

    func testAppendReturnsStoredTimestamp() throws {
        let store = makeStore()
        XCTAssertEqual(try store.append(sample(day0 + 10.3), interval: 1), Date(timeIntervalSince1970: day0 + 10))
        XCTAssertEqual(try store.append(sample(day0 + 11.4), interval: 1), Date(timeIntervalSince1970: day0 + 11),
                       "on-schedule sample is stored at its tick")
        XCTAssertNil(try store.append(sample(day0 + 11.45), interval: 1), "more than half an interval early: duplicate, dropped")
        XCTAssertEqual(try store.append(sample(day0 + 11.6), interval: 1), Date(timeIntervalSince1970: day0 + 12),
                       "within half an interval of the next tick")
    }

    // MARK: - Segments

    func testSegmentBreaks() throws {
        let store = makeStore()
        for i in 0..<5 { try store.append(sample(day0 + 1000 + Double(i)), interval: 1) }
        try store.append(sample(day0 + 1004.3), interval: 1)                                  // early duplicate
        for i in 0..<3 { try store.append(sample(day0 + 1010 + Double(i) * 5), interval: 5) } // interval change
        for i in 0..<2 { try store.append(sample(day0 + 2000 + Double(i) * 5), interval: 5) } // gap
        try store.breakSegment()
        try store.append(sample(day0 + 2010), interval: 5)
        try store.close()

        let segs = read(day0, day0 + 86_399)
        XCTAssertEqual(segs.map(\.count), [5, 3, 2, 1])
        XCTAssertEqual(segs.map(\.interval), [1, 5, 5, 5])
        XCTAssertEqual(segs.map { $0.start.timeIntervalSince1970 - day0 }, [1000, 1010, 2000, 2010])
    }

    func testDayRollover() throws {
        let store = makeStore()
        for i in 0..<4 { try store.append(sample(day0 + 86_400 - 10 + Double(i) * 5), interval: 5) }
        try store.close()

        XCTAssertTrue(FileManager.default.fileExists(atPath: file(day: 20_000).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file(day: 20_001).path))
        let segs = read(day0, day0 + 2 * 86_400)
        XCTAssertEqual(segs.map(\.count), [2, 2])
        XCTAssertEqual(segs[1].start.timeIntervalSince1970, day0 + 86_400, "continuation keeps the schedule")
    }

    func testReadTrimsToRange() throws {
        let store = makeStore()
        for i in 0..<5 { try store.append(sample(day0 + 1000 + Double(i)), interval: 1) }
        for i in 0..<3 { try store.append(sample(day0 + 1010 + Double(i) * 5), interval: 5) }
        try store.close()

        let segs = read(day0 + 1001.5, day0 + 1015)
        XCTAssertEqual(segs.map(\.count), [3, 2])
        XCTAssertEqual(segs[0].start.timeIntervalSince1970, day0 + 1002)
        XCTAssertTrue(read(day0 + 5000, day0 + 6000).isEmpty)
        XCTAssertTrue(read(day0 + 6000, day0 + 5000).isEmpty)
    }

    func testUnflushedSamplesAreNotRead() throws {
        let store = BatteryStore(directory: dir, flushInterval: 3600)
        for i in 0..<3 { try store.append(sample(day0 + Double(i)), interval: 1) }
        XCTAssertTrue(read(day0, day0 + 10).isEmpty)
        try store.flush()
        XCTAssertEqual(read(day0, day0 + 10).map(\.count), [3])
    }

    // MARK: - Recovery

    func testTornTrailingRecord() throws {
        let store = makeStore()
        for i in 0..<10 { try store.append(sample(day0 + Double(i)), interval: 1) }
        try store.close()

        let h = try FileHandle(forWritingTo: file(day: 20_000))
        try h.seekToEnd()
        try h.write(contentsOf: Data([0x10, 0x27, 0x05]))  // half a sample
        try h.close()
        XCTAssertEqual(read(day0, day0 + 100).map(\.count), [10], "reader ignores the torn tail")

        let store2 = makeStore()
        for i in 0..<3 { try store2.append(sample(day0 + 20 + Double(i)), interval: 1) }
        try store2.close()
        XCTAssertEqual(read(day0, day0 + 100).map(\.count), [10, 3], "writer truncates it, relaunch starts a segment")
    }

    func testTornSegmentHeader() throws {
        var data = Data(BatteryStore.magic) + [BatteryStore.version, 0, 0, 0]
        data += [0xFF, 0xFF, 0x01, 0x00, 0x00]  // 5 of 8 header bytes
        let parsed = BatteryStore.parse(data)
        XCTAssertTrue(parsed.headerOK)
        XCTAssertTrue(parsed.segments.isEmpty)
        XCTAssertEqual(parsed.validEnd, BatteryStore.fileHeaderSize)
    }

    func testCorruptFileIsMovedAside() throws {
        try Data("garbage!garbage!".utf8).write(to: file(day: 20_000))
        let store = makeStore()
        try store.append(sample(day0 + 5), interval: 1)
        try store.close()

        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains("2024-10-04.bin.bad"))
        XCTAssertEqual(read(day0, day0 + 10).map(\.count), [1])
    }

    // MARK: - Retention

    func testRetentionPruning() throws {
        for d in [19_980, 19_988, 19_989, 19_999] { try Data(BatteryStore.magic).write(to: file(day: d)) }
        try Data().write(to: file(day: 19_980).appendingPathExtension("bad"))
        try Data("keep".utf8).write(to: dir.appendingPathComponent("notes.txt"))

        let store = makeStore()  // retentionDays 11
        try store.append(sample(day0 + 5), interval: 1)
        try store.close()

        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        // Writing day 20 000 (2024-10-04) keeps day 19 989 (exactly 11 days back) and newer.
        XCTAssertEqual(names, ["2024-09-23.bin", "2024-10-03.bin", "2024-10-04.bin", "notes.txt"],
                       "files older than 11 days go, including .bad; unrelated files stay")
    }

    // MARK: - Size

    func testOneDayAtOneSecondFitsBudget() throws {
        let store = BatteryStore(directory: dir)
        for i in 0..<86_400 { try store.append(sample(day0 + Double(i), pct: Double(i % 10_000) / 100), interval: 1) }
        try store.close()

        let size = try FileManager.default.attributesOfItem(atPath: file(day: 20_000).path)[.size] as? Int
        XCTAssertEqual(size, BatteryStore.fileHeaderSize + BatteryStore.segmentHeaderSize + 86_400 * BatteryStore.sampleSize)
        XCTAssertEqual(read(day0, day0 + 86_400).map(\.count), [86_400])
    }
}
