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

/// Battery history reduced to min/max per fixed time bucket, split into runs at recording gaps.
///
/// Buckets are aligned to absolute time (index = unix seconds / bucketSeconds), so as the window
/// slides, buckets are only added at the end and dropped at the start. Keeping min and max rather
/// than averages keeps short spikes visible at every zoom level.
///
/// The Energy Mode is kept at full resolution instead, as spans of unchanged mode.
struct BatteryBuckets {
    struct Bucket: Equatable {
        let index: Int
        var charge = MinMax()
        var system = MinMax()
        var battery = MinMax()
    }

    /// One pixel column of a chart.
    struct Column: Equatable {
        let x: Int
        let min: Float
        let max: Float
    }

    /// A continuous stretch in one Energy Mode. Holds from its first sample until the next sample
    /// in its run, so back-to-back spans meet without a gap.
    struct ModeSpan: Equatable {
        let mode: PowerMode
        var start: TimeInterval
        var end: TimeInterval

        var duration: TimeInterval { end - start }

        /// "45s", "12m", "5h 12m", "2d 3h".
        var durationLabel: String {
            let s = Int(duration.rounded())
            if s < 60 { return "\(s)s" }
            let m = s / 60
            if m < 60 { return "\(m)m" }
            if m < 1_440 { return "\(m / 60)h \(m % 60)m" }
            return "\(m / 1_440)d \(m % 1_440 / 60)h"
        }
    }

    /// Buckets per displayed range. More than any chart is wide, so `columns` can merge them.
    static let bucketsPerRange = 2_000
    /// Consecutive samples further apart than this many intervals are separated by a gap.
    static let gapFactor = 1.5

    let bucketSeconds: TimeInterval
    /// Oldest first. Within a run samples are contiguous; draw each run as its own line.
    private(set) var runs: [[Bucket]] = []
    /// Oldest first. Recording gaps and samples with unknown mode end a span.
    private(set) var modeSpans: [ModeSpan] = []
    private(set) var lastTime: TimeInterval?
    private var lastInterval: TimeInterval = 0
    /// Whether the last mode span is still being extended by new samples.
    private var modeSpanOpen = false

    init(range: TimeInterval) {
        bucketSeconds = range / Double(Self.bucketsPerRange)
    }

    /// Adds one sample. Samples must arrive in time order; anything not newer than the last is ignored.
    mutating func add(time t: TimeInterval, interval: TimeInterval, charge: Float, system: Float, battery: Float,
                      mode: PowerMode? = nil) {
        if let last = lastTime {
            guard t > last else { return }
            if t - last > Self.gapFactor * Swift.max(interval, lastInterval) { runs.append([]); modeSpanOpen = false }
        } else {
            runs.append([])
        }
        lastTime = t
        lastInterval = interval
        addMode(mode, at: t)

        let r = runs.count - 1
        let index = Int((t / bucketSeconds).rounded(.down))
        if runs[r].last?.index != index { runs[r].append(Bucket(index: index)) }
        let b = runs[r].count - 1
        runs[r][b].charge.add(charge)
        runs[r][b].system.add(system)
        runs[r][b].battery.add(battery)
    }

    private mutating func addMode(_ mode: PowerMode?, at t: TimeInterval) {
        if modeSpanOpen { modeSpans[modeSpans.count - 1].end = t }
        guard let mode else { modeSpanOpen = false; return }
        if modeSpanOpen && modeSpans[modeSpans.count - 1].mode == mode { return }
        modeSpans.append(ModeSpan(mode: mode, start: t, end: t))
        modeSpanOpen = true
    }

    mutating func add(_ segment: BatterySegment) {
        let start = segment.start.timeIntervalSince1970
        for i in 0..<segment.count {
            add(time: start + Double(i) * segment.interval, interval: segment.interval,
                charge: segment.chargePct[i], system: segment.systemPowerW[i], battery: segment.batteryPowerW[i],
                mode: i < segment.powerMode.count ? segment.powerMode[i] : nil)
        }
    }

    mutating func add(_ recorded: RecordedSample) {
        let s = recorded.sample
        add(time: s.timestamp.timeIntervalSince1970, interval: Double(recorded.interval),
            charge: Float(s.chargePct),
            system: Float(s.systemPowerW ?? .nan),
            battery: Float(s.batteryPowerW ?? .nan),
            mode: s.powerMode)
    }

    /// Drops buckets that end before `time` and cuts mode spans off at `time`.
    mutating func trim(before time: TimeInterval) {
        let first = Int((time / bucketSeconds).rounded(.down))
        while let run = runs.first, run[run.count - 1].index < first { runs.removeFirst() }
        if let k = runs.first?.firstIndex(where: { $0.index >= first }), k > 0 { runs[0].removeFirst(k) }
        if let k = modeSpans.firstIndex(where: { $0.end >= time }) {
            modeSpans.removeFirst(k)
            modeSpans[0].start = Swift.max(modeSpans[0].start, time)
        } else {
            modeSpans = []
            modeSpanOpen = false
        }
    }

    /// Smallest and largest value of one series across all buckets, for scaling the y axis.
    func extent(_ series: KeyPath<Bucket, MinMax>) -> MinMax {
        var m = MinMax()
        for run in runs {
            for bucket in run {
                let v = bucket[keyPath: series]
                m.add(v.min)
                m.add(v.max)
            }
        }
        return m
    }

    /// Reduces one series to at most one min/max column per pixel for a chart `width` px wide
    /// showing `windowStart ..< windowStart + range`. One array per run, oldest first;
    /// runs and buckets without values for this series are left out.
    func columns(_ series: KeyPath<Bucket, MinMax>, width: Int,
                 windowStart: TimeInterval, range: TimeInterval) -> [[Column]] {
        guard width > 0, range > 0 else { return [] }
        let scale = Double(width) / range
        var result: [[Column]] = []
        for run in runs {
            var cols: [Column] = []
            for bucket in run {
                let v = bucket[keyPath: series]
                guard !v.isEmpty else { continue }
                let mid = (Double(bucket.index) + 0.5) * bucketSeconds
                let px = ((mid - windowStart) * scale).rounded(.down)
                guard px >= 0 else { continue }
                // The newest bucket's midpoint can sit just past the right edge.
                let x = Int(Swift.min(px, Double(width - 1)))
                if let last = cols.last, last.x == x {
                    cols[cols.count - 1] = Column(x: x, min: Swift.min(last.min, v.min), max: Swift.max(last.max, v.max))
                } else {
                    cols.append(Column(x: x, min: v.min, max: v.max))
                }
            }
            if !cols.isEmpty { result.append(cols) }
        }
        return result
    }
}

/// Chart data for the selected range: history loaded from disk off the main thread, then kept
/// current from the recorder's live ticks.
@MainActor
final class BatteryHistory: ObservableObject {

    @Published var range: BatteryRange {
        didSet { if range != oldValue { reload() } }
    }
    @Published private(set) var buckets: BatteryBuckets
    /// Right edge of the charts: the newest recorded tick, or the load time.
    @Published private(set) var now: Date
    @Published private(set) var isLoading = false

    var windowStart: TimeInterval { now.timeIntervalSince1970 - range.seconds }

    private let recorder: BatteryRecorder
    /// Ticks that arrive while a load is in flight, applied once it lands.
    private var pending: [RecordedSample] = []
    private var loadID = 0
    private var subscription: AnyCancellable?

    init(recorder: BatteryRecorder, range: BatteryRange) {
        self.recorder = recorder
        self.range = range
        buckets = BatteryBuckets(range: range.seconds)
        now = Date()
        subscription = recorder.$lastRecorded
            .compactMap { $0 }
            .sink { [weak self] in self?.receive($0) }
        reload()
    }

    func columns(_ series: KeyPath<BatteryBuckets.Bucket, MinMax>, width: Int) -> [[BatteryBuckets.Column]] {
        buckets.columns(series, width: width, windowStart: windowStart, range: range.seconds)
    }

    /// Reloads the selected range from disk. Only the flush and the final swap run on the main thread.
    func reload() {
        loadID += 1
        let id = loadID
        let seconds = range.seconds
        let directory = recorder.store.directory
        recorder.flush()
        let end = Date()
        isLoading = true
        pending = []
        Task.detached(priority: .userInitiated) { [weak self] in
            var loaded = BatteryBuckets(range: seconds)
            for segment in BatteryStore.read(from: end - seconds, to: end, directory: directory) {
                loaded.add(segment)
            }
            await self?.finishLoad(id: id, buckets: loaded, end: end)
        }
    }

    private func finishLoad(id: Int, buckets loaded: BatteryBuckets, end: Date) {
        guard id == loadID else { return }  // superseded by a newer range
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
