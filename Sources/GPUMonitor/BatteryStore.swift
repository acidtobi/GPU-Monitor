import Foundation

/// One unbroken run of recorded samples. Sample i was recorded at start + i × interval.
/// Each series is its own array; missing power values are NaN.
struct BatterySegment {
    var start: Date
    var interval: TimeInterval
    var chargePct: [Float] = []
    var systemPowerW: [Float] = []
    var batteryPowerW: [Float] = []

    var count: Int { chargePct.count }

    func timestamp(at i: Int) -> Date { start.addingTimeInterval(Double(i) * interval) }
}

/// Append-only binary storage for the battery time series.
///
/// One file per UTC day, `<directory>/YYYY-MM-DD.bin`, all integers little-endian:
///
///     file header     8 B   "BATT", u8 version, 3 B reserved
///     segment header  8 B   u16 0xFFFF, u16 interval seconds, u32 start unix seconds
///     sample          6 B   u16 chargePct × 100 (0…10000), i16 systemPower in 10 mW, i16 batteryPower in 10 mW
///
/// Sample timestamps are implicit (segment start + n × interval), so a sample costs 6 bytes:
/// ~518 KB per day at 1 s. 0xFFFF can never be a valid charge value, which is what tells a
/// segment header apart from a sample. Int16.min marks a missing power value.
///
/// A new segment starts on launch, interval change, gaps (sleep, missed ticks) and day rollover.
/// Writing is not thread-safe. `read` only touches flushed bytes and is safe from any thread.
final class BatteryStore {

    static let magic = Array("BATT".utf8)
    static let version: UInt8 = 1
    static let fileHeaderSize = 8
    static let segmentHeaderSize = 8
    static let sampleSize = 6
    static let segmentMarker: UInt16 = 0xFFFF
    static let missingPower = Int16.min

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GPUMonitor/battery", isDirectory: true)
    }

    let directory: URL
    /// Day files older than this many days (relative to the day being written) are deleted.
    let retentionDays: Int
    /// Buffered samples are written to disk at most this many seconds apart.
    let flushInterval: TimeInterval

    private var handle: FileHandle?
    private var currentDay: Int?
    private var segment: (start: Int, interval: Int, count: Int)?
    private var lastTimestamp: Int?
    private var buffer = Data()
    private var lastFlush = Date()

    init(directory: URL = BatteryStore.defaultDirectory,
         retentionDays: Int = 11,
         flushInterval: TimeInterval = 60) {
        self.directory = directory
        self.retentionDays = retentionDays
        self.flushInterval = flushInterval
    }

    deinit { try? close() }

    // MARK: - Writing

    /// Appends one sample taken on an `interval`-second schedule.
    /// Samples within half an interval of the next expected tick continue the current segment
    /// (and are stored at that tick's time); later ones start a new segment; earlier ones are
    /// dropped as duplicate ticks.
    /// Returns the timestamp the sample was stored at, or nil if it was dropped.
    @discardableResult
    func append(_ sample: BatterySample, interval: Int) throws -> Date? {
        precondition(interval > 0 && interval <= Int(UInt16.max))
        let t = sample.timestamp.timeIntervalSince1970
        let tolerance = Double(interval) / 2
        var start = Int(t.rounded(.down))

        if let seg = segment, seg.interval == interval {
            let expected = seg.start + seg.count * interval
            if t < Double(expected) - tolerance { return nil }
            if t <= Double(expected) + tolerance {
                if Self.day(of: expected) == currentDay {
                    writeSample(sample)
                    segment?.count += 1
                    lastTimestamp = expected
                    try flushIfDue()
                    return Date(timeIntervalSince1970: Double(expected))
                }
                start = expected  // on schedule, only the day rolled over
            }
        }

        if let last = lastTimestamp, start <= last { return nil }
        if Self.day(of: start) != currentDay { try open(day: Self.day(of: start)) }

        buffer.appendLE(Self.segmentMarker)
        buffer.appendLE(UInt16(interval))
        buffer.appendLE(UInt32(clamping: start))
        segment = (start, interval, 0)
        writeSample(sample)
        segment?.count = 1
        lastTimestamp = start
        try flushIfDue()
        return Date(timeIntervalSince1970: Double(start))
    }

    /// Ends the current segment, e.g. before sleep. The next sample opens a new one.
    func breakSegment() throws {
        try flush()
        segment = nil
    }

    func flush() throws {
        guard !buffer.isEmpty, let handle else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
        lastFlush = Date()
    }

    func close() throws {
        try flush()
        try handle?.close()
        handle = nil
        currentDay = nil
        segment = nil
    }

    private func flushIfDue() throws {
        if Date().timeIntervalSince(lastFlush) >= flushInterval { try flush() }
    }

    private func writeSample(_ s: BatterySample) {
        buffer.appendLE(Self.encodePct(s.chargePct))
        buffer.appendLE(Self.encodePower(s.systemPowerW))
        buffer.appendLE(Self.encodePower(s.batteryPowerW))
    }

    /// Switches to the file for `day`: drops a torn trailing record left by a crash, moves an
    /// unreadable file aside, and prunes files past the retention window.
    private func open(day: Int) throws {
        try close()
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = Self.fileURL(day: day, in: directory)

        if let data = try? Data(contentsOf: url), data.count >= Self.fileHeaderSize {
            let parsed = Self.parse(data)
            if parsed.headerOK {
                let h = try FileHandle(forWritingTo: url)
                try h.truncate(atOffset: UInt64(parsed.validEnd))
                try h.seekToEnd()
                handle = h
            } else {
                let aside = url.appendingPathExtension("bad")
                try? fm.removeItem(at: aside)
                try fm.moveItem(at: url, to: aside)
            }
        }
        if handle == nil {
            var header = Data(Self.magic)
            header.append(Self.version)
            header.append(contentsOf: [0, 0, 0])
            guard fm.createFile(atPath: url.path, contents: header) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            handle = h
        }
        currentDay = day
        prune(today: day)
    }

    private func prune(today: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            // Also catches "<day>.bin.bad" files moved aside by open(day:).
            guard let day = Self.day(fromFileName: name), day < today - retentionDays else { continue }
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: - Reading

    /// Returns the flushed segments overlapping `from…to`, trimmed to that range, oldest first.
    static func read(from: Date, to: Date, directory: URL = defaultDirectory) -> [BatterySegment] {
        let lo = from.timeIntervalSince1970, hi = to.timeIntervalSince1970
        guard lo <= hi else { return [] }
        var result: [BatterySegment] = []
        for day in day(of: Int(lo.rounded(.down)))...day(of: Int(hi.rounded(.down))) {
            guard let data = try? Data(contentsOf: fileURL(day: day, in: directory)) else { continue }
            for seg in parse(data).segments {
                let start = seg.start.timeIntervalSince1970
                let first = max(0, Int(((lo - start) / seg.interval).rounded(.up)))
                let last = min(seg.count - 1, Int(((hi - start) / seg.interval).rounded(.down)))
                guard first <= last else { continue }
                result.append(BatterySegment(
                    start: seg.timestamp(at: first),
                    interval: seg.interval,
                    chargePct: Array(seg.chargePct[first...last]),
                    systemPowerW: Array(seg.systemPowerW[first...last]),
                    batteryPowerW: Array(seg.batteryPowerW[first...last])
                ))
            }
        }
        return result
    }

    struct Parsed {
        var headerOK = false
        var segments: [BatterySegment] = []
        /// Byte offset just past the last complete record.
        var validEnd = 0
    }

    /// Decodes a day file, stopping at the first incomplete or invalid record.
    static func parse(_ data: Data) -> Parsed {
        var out = Parsed()
        guard data.count >= fileHeaderSize,
              Array(data.prefix(magic.count)) == magic,
              data[data.startIndex + magic.count] == version else { return out }
        out.headerOK = true
        out.validEnd = fileHeaderSize

        data.withUnsafeBytes { raw in
            func u16(_ o: Int) -> UInt16 { UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt16.self)) }
            func i16(_ o: Int) -> Int16  { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: Int16.self)) }
            func u32(_ o: Int) -> UInt32 { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }

            var o = fileHeaderSize
            while o + 2 <= raw.count {
                let first = u16(o)
                if first == segmentMarker {
                    guard o + segmentHeaderSize <= raw.count else { break }
                    let interval = u16(o + 2)
                    guard interval > 0 else { break }
                    out.segments.append(BatterySegment(start: Date(timeIntervalSince1970: Double(u32(o + 4))),
                                                       interval: Double(interval)))
                    o += segmentHeaderSize
                } else {
                    guard first <= 10_000, !out.segments.isEmpty, o + sampleSize <= raw.count else { break }
                    let last = out.segments.count - 1
                    out.segments[last].chargePct.append(Float(first) / 100)
                    out.segments[last].systemPowerW.append(decodePower(i16(o + 2)))
                    out.segments[last].batteryPowerW.append(decodePower(i16(o + 4)))
                    o += sampleSize
                }
                out.validEnd = o
            }
        }
        out.segments.removeAll { $0.count == 0 }
        return out
    }

    // MARK: - Encoding

    static func encodePct(_ pct: Double) -> UInt16 {
        guard pct.isFinite else { return 0 }
        return UInt16((min(100, max(0, pct)) * 100).rounded())
    }

    /// Watts → 10 mW units, clamped to ±327.67 W. nil/NaN → missingPower.
    static func encodePower(_ watts: Double?) -> Int16 {
        guard let watts, watts.isFinite else { return missingPower }
        let v = min(Double(Int16.max), max(Double(missingPower) + 1, (watts * 100).rounded()))
        return Int16(v)
    }

    static func decodePower(_ v: Int16) -> Float {
        v == missingPower ? .nan : Float(v) / 100
    }

    // MARK: - Day files

    private static let secondsPerDay = 86_400

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Days since 1970-01-01 UTC.
    static func day(of unixSeconds: Int) -> Int {
        Int((Double(unixSeconds) / Double(secondsPerDay)).rounded(.down))
    }

    static func fileURL(day: Int, in directory: URL) -> URL {
        let date = Date(timeIntervalSince1970: Double(day * secondsPerDay))
        return directory.appendingPathComponent(dayFormatter.string(from: date) + ".bin")
    }

    static func day(fromFileName name: String) -> Int? {
        guard name.count >= 10, let date = dayFormatter.date(from: String(name.prefix(10))) else { return nil }
        return day(of: Int(date.timeIntervalSince1970))
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
