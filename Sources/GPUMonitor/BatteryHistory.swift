import Foundation
import Combine

/// Display ranges for the battery charts.
enum BatteryRange: Int, CaseIterable, Identifiable {
    case m5 = 300, m15 = 900, h1 = 3_600, h4 = 14_400, h24 = 86_400, d2 = 172_800, d4 = 345_600, d10 = 864_000

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }

    var label: String {
        switch self {
        case .m5:  "5m"
        case .m15: "15m"
        case .h1:  "1h"
        case .h4:  "4h"
        case .h24: "24h"
        case .d2:  "2d"
        case .d4:  "4d"
        case .d10: "10d"
        }
    }

    /// Spacing of the vertical grid lines, counted back from now.
    var gridStep: TimeInterval {
        switch self {
        case .m5:  60
        case .m15: 300
        case .h1:  900
        case .h4:  3_600
        case .h24: 21_600
        case .d2:  43_200
        case .d4:  86_400
        case .d10: 172_800
        }
    }

    /// Time-axis label, e.g. "−45 min", "−18 h", "−8 d", "now". Days only from 4d up.
    func axisLabel(secondsAgo s: Int) -> String {
        if s == 0 { return "now" }
        if rawValue >= BatteryRange.d4.rawValue, s % 86_400 == 0 { return "−\(s / 86_400) d" }
        if s % 3_600 == 0 { return "−\(s / 3_600) h" }
        return "−\(s / 60) min"
    }
}

/// How a chart column sums up the samples that fall into it.
enum ChartStyle: String, CaseIterable, Identifiable {
    /// Mean line over an area down to zero.
    case average
    /// Band from the smallest to the largest sample.
    case minMax
    /// Mean line inside a band holding the middle 95% of the samples.
    case averageBand
    /// A box plot per column: median line, a band for the middle half of the samples and a
    /// faint one from the smallest to the largest.
    case quartiles

    var id: String { rawValue }

    var label: String {
        switch self {
        case .average:     "Average"
        case .minMax:      "Min–max band"
        case .averageBand: "Average + 95% band"
        case .quartiles:   "Median + quartiles"
        }
    }

    var help: String {
        switch self {
        case .average:     "average per pixel"
        case .minMax:      "band from minimum to maximum per pixel"
        case .averageBand: "average per pixel, band where the middle 95% of the samples lie"
        case .quartiles:   "median per pixel, band for the middle 50% of the samples, faint band from minimum to maximum"
        }
    }

    /// Value the line passes through; nil if this style draws no line.
    func line(_ s: Summary) -> Float? {
        switch self {
        case .average, .averageBand: s.mean
        case .quartiles:             s.median
        case .minMax:                nil
        }
    }

    /// Bottom and top of the shaded bands, outermost first.
    func bands(_ s: Summary) -> [(low: Float, high: Float)] {
        switch self {
        case .average:     []
        case .minMax:      [(s.min, s.max)]
        case .averageBand: [(s.p2_5, s.p97_5)]
        case .quartiles:   [(s.min, s.max), (s.p25, s.p75)]
        }
    }
}

/// Smallest and largest value seen; NaN while empty. NaN inputs (missing values) are ignored.
struct MinMax: Equatable {
    var min: Float = .nan
    var max: Float = .nan

    var isEmpty: Bool { min.isNaN }

    mutating func add(_ v: Float) {
        guard !v.isNaN else { return }
        if isEmpty { min = v; max = v } else { min = Swift.min(min, v); max = Swift.max(max, v) }
    }
}

/// One series summed up over one bucket, with everything each ChartStyle needs.
/// All NaN while the bucket has no values for the series.
struct Summary {
    var min: Float = .nan
    var max: Float = .nan
    var mean: Float = .nan
    var median: Float = .nan
    /// Percentiles: the middle 95% of the samples lie between p2_5 and p97_5, the middle half
    /// between p25 and p75.
    var p2_5: Float = .nan
    var p25: Float = .nan
    var p75: Float = .nan
    var p97_5: Float = .nan

    var isEmpty: Bool { mean.isNaN }

    init() {}

    /// NaN values (missing) are ignored.
    init(_ values: [Float]) {
        var sorted = values.filter { !$0.isNaN }
        guard !sorted.isEmpty else { return }
        sorted.sort()
        min = sorted[0]
        max = sorted[sorted.count - 1]
        mean = Float(sorted.reduce(0.0) { $0 + Double($1) } / Double(sorted.count))
        median = Self.quantile(sorted, 0.5)
        p2_5 = Self.quantile(sorted, 0.025)
        p25 = Self.quantile(sorted, 0.25)
        p75 = Self.quantile(sorted, 0.75)
        p97_5 = Self.quantile(sorted, 0.975)
    }

    /// Quantile of sorted values, interpolating between the two closest ranks (R-7, numpy's default).
    static func quantile(_ sorted: [Float], _ p: Double) -> Float {
        let h = Double(sorted.count - 1) * p
        let i = Int(h.rounded(.down))
        guard i + 1 < sorted.count else { return sorted[i] }
        return sorted[i] + Float(h - Double(i)) * (sorted[i + 1] - sorted[i])
    }
}

/// Battery history summed up per fixed time bucket, split into runs at recording gaps.
///
/// A bucket is one pixel column wide (range / columns seconds) and aligned to absolute time
/// (index = unix seconds / bucketSeconds), so as the window slides the columns scroll along
/// unchanged: buckets are only added at the end and dropped at the start.
struct BatteryBuckets {
    struct Bucket {
        let index: Int
        var charge = Summary()
        var system = Summary()
        var battery = Summary()
    }

    /// One pixel column of a chart. `x` is the column's center in pixels from the left edge.
    struct Column {
        let x: Double
        let summary: Summary
    }

    /// Consecutive samples further apart than this many intervals are separated by a gap.
    static let gapFactor = 1.5

    private static let series: [WritableKeyPath<Bucket, Summary>] = [\.charge, \.system, \.battery]

    /// Raw samples of the newest bucket, whose summaries change with every sample added.
    /// Values are indexed like `series`.
    private struct OpenBucket {
        let index: Int
        var values: [[Float]] = [[], [], []]
        /// Samples were added since the summaries were last computed.
        var dirty = false
    }

    let bucketSeconds: TimeInterval
    /// Oldest first. Within a run samples are contiguous; draw each run as its own line.
    private(set) var runs: [[Bucket]] = []
    private(set) var lastTime: TimeInterval?
    private var lastInterval: TimeInterval = 0
    /// The last bucket of the last run.
    private var open: OpenBucket?

    /// Buckets for a chart `columns` pixels wide showing `range` seconds.
    init(range: TimeInterval, columns: Int) {
        bucketSeconds = range / Double(Swift.max(1, columns))
    }

    /// Adds one sample. Samples must arrive in time order; anything not newer than the last is ignored.
    mutating func add(time t: TimeInterval, interval: TimeInterval, charge: Float, system: Float, battery: Float) {
        append(time: t, interval: interval, values: [charge, system, battery])
        summarizeOpen()
    }

    mutating func add(_ segment: BatterySegment) {
        let start = segment.start.timeIntervalSince1970
        for i in 0..<segment.count {
            append(time: start + Double(i) * segment.interval, interval: segment.interval,
                   values: [segment.chargePct[i], segment.systemPowerW[i], segment.batteryPowerW[i]])
        }
        summarizeOpen()
    }

    mutating func add(_ recorded: RecordedSample) {
        let s = recorded.sample
        add(time: s.timestamp.timeIntervalSince1970, interval: Double(recorded.interval),
            charge: Float(s.chargePct),
            system: Float(s.systemPowerW ?? .nan),
            battery: Float(s.batteryPowerW ?? .nan))
    }

    /// Adds a sample to its bucket. The newest bucket is summed up when it's complete or by
    /// summarizeOpen(), so a bulk load sorts each bucket once.
    private mutating func append(time t: TimeInterval, interval: TimeInterval, values: [Float]) {
        if let last = lastTime {
            guard t > last else { return }
            if runs.isEmpty || t - last > Self.gapFactor * Swift.max(interval, lastInterval) {
                closeOpen()
                runs.append([])
            }
        } else {
            runs.append([])
        }
        lastTime = t
        lastInterval = interval

        let r = runs.count - 1
        let index = Int((t / bucketSeconds).rounded(.down))
        if runs[r].last?.index != index {
            closeOpen()
            runs[r].append(Bucket(index: index))
            open = OpenBucket(index: index)
        }
        for s in values.indices { open?.values[s].append(values[s]) }
        open?.dirty = true
    }

    private mutating func closeOpen() {
        summarizeOpen()
        open = nil
    }

    private mutating func summarizeOpen() {
        guard let o = open, o.dirty, let r = runs.indices.last,
              let i = runs[r].indices.last, runs[r][i].index == o.index else { return }
        for (s, path) in Self.series.enumerated() { runs[r][i][keyPath: path] = Summary(o.values[s]) }
        open?.dirty = false
    }

    /// Drops buckets that end before `time`.
    mutating func trim(before time: TimeInterval) {
        let first = Int((time / bucketSeconds).rounded(.down))
        while let run = runs.first, run[run.count - 1].index < first { runs.removeFirst() }
        if let k = runs.first?.firstIndex(where: { $0.index >= first }), k > 0 { runs[0].removeFirst(k) }
        if runs.isEmpty { open = nil }
    }

    /// Smallest and largest value one series draws in `style`, for scaling the y axis.
    func extent(_ series: KeyPath<Bucket, Summary>, style: ChartStyle) -> MinMax {
        var m = MinMax()
        for run in runs {
            for bucket in run {
                let s = bucket[keyPath: series]
                if let v = style.line(s) { m.add(v) }
                for band in style.bands(s) { m.add(band.low); m.add(band.high) }
            }
        }
        return m
    }

    /// Places one series' buckets on the pixel columns of a chart `width` px wide showing
    /// `windowStart ..< windowStart + range`. One array per run, oldest first; runs and buckets
    /// without values for this series are left out.
    func columns(_ series: KeyPath<Bucket, Summary>, width: Int,
                 windowStart: TimeInterval, range: TimeInterval) -> [[Column]] {
        guard width > 0, range > 0 else { return [] }
        let scale = Double(width) / range
        var result: [[Column]] = []
        for run in runs {
            var cols: [Column] = []
            for bucket in run {
                let s = bucket[keyPath: series]
                guard !s.isEmpty else { continue }
                let x = ((Double(bucket.index) + 0.5) * bucketSeconds - windowStart) * scale
                guard x > -1 else { continue }
                // The newest bucket's center can sit up to half a pixel past the right edge.
                cols.append(Column(x: Swift.min(x, Double(width) - 0.5), summary: s))
            }
            if !cols.isEmpty { result.append(cols) }
        }
        return result
    }
}

/// Chart data for the selected range: history loaded from disk off the main thread, then kept
/// current from the recorder's live ticks. Nothing loads until the view reports its chart width.
@MainActor
final class BatteryHistory: ObservableObject {

    @Published var range: BatteryRange {
        didSet { if range != oldValue { reload() } }
    }
    @Published private(set) var buckets: BatteryBuckets
    /// Right edge of the charts: the newest recorded tick, or the load time.
    @Published private(set) var now: Date
    @Published private(set) var isLoading = true

    var windowStart: TimeInterval { now.timeIntervalSince1970 - range.seconds }

    private let recorder: BatteryRecorder
    /// Ticks that arrive while a load is in flight, applied once it lands.
    private var pending: [RecordedSample] = []
    private var loadID = 0
    private var subscription: AnyCancellable?
    /// Chart width in pixel columns, one bucket each. 0 until the view is laid out.
    private var columnCount = 0
    private var resizeTask: Task<Void, Never>?

    init(recorder: BatteryRecorder, range: BatteryRange) {
        self.recorder = recorder
        self.range = range
        buckets = BatteryBuckets(range: range.seconds, columns: 1)
        now = Date()
        subscription = recorder.$lastRecorded
            .compactMap { $0 }
            .sink { [weak self] in self?.receive($0) }
    }

    func columns(_ series: KeyPath<BatteryBuckets.Bucket, Summary>, width: Int) -> [[BatteryBuckets.Column]] {
        buckets.columns(series, width: width, windowStart: windowStart, range: range.seconds)
    }

    /// Sets the chart width in pixels. The first width loads right away; later ones (window
    /// resizing) once the width has settled. Until then the old buckets are stretched to fit.
    func resize(columns: Int) {
        guard columns > 0, columns != columnCount else { return }
        let first = columnCount == 0
        columnCount = columns
        resizeTask?.cancel()
        if first { reload(); return }
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    /// Reloads the selected range from disk. Only the flush and the final swap run on the main thread.
    func reload() {
        guard columnCount > 0 else { return }
        loadID += 1
        let id = loadID
        let seconds = range.seconds
        let columns = columnCount
        let directory = recorder.store.directory
        recorder.flush()
        let end = Date()
        isLoading = true
        pending = []
        Task.detached(priority: .userInitiated) { [weak self] in
            var loaded = BatteryBuckets(range: seconds, columns: columns)
            for segment in BatteryStore.read(from: end - seconds, to: end, directory: directory) {
                loaded.add(segment)
            }
            await self?.finishLoad(id: id, buckets: loaded, end: end)
        }
    }

    private func finishLoad(id: Int, buckets loaded: BatteryBuckets, end: Date) {
        guard id == loadID else { return }  // superseded by a newer range or width
        buckets = loaded
        now = end
        isLoading = false
        // Ticks flushed during the load are already in `loaded`; add() skips them.
        for r in pending { apply(r) }
        pending = []
    }

    private func receive(_ r: RecordedSample) {
        if isLoading { pending.append(r) } else { apply(r) }
    }

    private func apply(_ r: RecordedSample) {
        now = Swift.max(now, r.sample.timestamp)
        var b = buckets  // mutate a copy so observers see one change per tick
        b.add(r)
        b.trim(before: windowStart)
        buckets = b
    }
}
