import AppKit

/// A sample as written to the store: its timestamp is snapped to the recording schedule.
struct RecordedSample: Equatable {
    let sample: BatterySample
    let interval: Int
}

/// Samples the battery on a fixed schedule and appends to BatteryStore for as long as the app
/// runs, whether or not the window is open. Ticks fall on multiples of the interval in unix time
/// (…:00, :05, :10 at 5 s), so the store's implicit timestamps don't drift.
@MainActor
final class BatteryRecorder: ObservableObject {

    /// Selectable recording intervals in seconds.
    nonisolated static let intervals = [1, 5, 10, 30, 60]
    nonisolated static let defaultInterval = 5
    nonisolated static let intervalKey = "batteryIntervalSeconds"

    /// Recording interval in seconds, one of `intervals`. Persisted; takes effect on the next tick.
    @Published var interval: Int {
        didSet { intervalChanged(from: oldValue) }
    }
    /// Latest reading including charger state, updated every tick.
    @Published private(set) var latest: BatteryReading?
    /// The most recent sample written to the store.
    @Published private(set) var lastRecorded: RecordedSample?
    @Published private(set) var hasBattery: Bool
    /// Last write error, cleared by the next successful write.
    @Published private(set) var storeError: String?

    let store: BatteryStore
    private let sampler: BatterySampler
    private let defaults: UserDefaults
    private var loop: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(store: BatteryStore = BatteryStore(),
         sampler: BatterySampler = BatterySampler(),
         defaults: UserDefaults = .standard) {
        self.store = store
        self.sampler = sampler
        self.defaults = defaults
        let saved = defaults.integer(forKey: Self.intervalKey)
        interval = Self.intervals.contains(saved) ? saved : Self.defaultInterval
        let first = sampler.sample()
        latest = first
        hasBattery = first != nil
        guard hasBattery else { return }  // desktop Mac: stay idle

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.pause() }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.start() }
        observe(.default, NSApplication.willTerminateNotification) { $0.stop() }
        start()
    }

    deinit {
        loop?.cancel()
        for (center, token) in observers { center.removeObserver(token) }
    }

    /// Writes buffered samples to disk so a following `BatteryStore.read` sees them.
    func flush() {
        do { try store.flush() } catch { storeError = error.localizedDescription }
    }

    /// First tick strictly after `time` on an `interval`-second schedule.
    nonisolated static func nextTick(after time: TimeInterval, interval: Int) -> TimeInterval {
        let i = Double(interval)
        return ((time / i).rounded(.down) + 1) * i
    }

    // MARK: - Loop

    private func start() {
        loop?.cancel()
        let interval = interval
        loop = Task { [weak self] in
            var next = Self.nextTick(after: Date().timeIntervalSince1970, interval: interval)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(next - Date().timeIntervalSince1970))
                guard !Task.isCancelled, let self else { return }
                self.tick()
                // Normally next + interval. After a stall, skip the missed ticks; the store
                // sees the jump and starts a new segment.
                next = max(next + Double(interval),
                           Self.nextTick(after: Date().timeIntervalSince1970, interval: interval))
            }
        }
    }

    private func tick() {
        guard let reading = sampler.sample() else { return }
        latest = reading
        do {
            if let stored = try store.append(reading.sample, interval: interval) {
                let s = reading.sample
                lastRecorded = RecordedSample(
                    sample: BatterySample(timestamp: stored, chargePct: s.chargePct,
                                          systemPowerW: s.systemPowerW, batteryPowerW: s.batteryPowerW),
                    interval: interval)
            }
            storeError = nil
        } catch {
            storeError = error.localizedDescription
        }
    }

    /// Before sleep: stop ticking and end the segment, so the time asleep is a gap on disk.
    private func pause() {
        loop?.cancel()
        loop = nil
        do { try store.breakSegment() } catch { storeError = error.localizedDescription }
    }

    private func stop() {
        loop?.cancel()
        loop = nil
        try? store.close()
    }

    private func intervalChanged(from old: Int) {
        guard interval != old else { return }
        guard Self.intervals.contains(interval) else { interval = old; return }
        defaults.set(interval, forKey: Self.intervalKey)
        guard hasBattery else { return }
        do { try store.breakSegment() } catch { storeError = error.localizedDescription }
        if loop != nil { start() }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ action: @escaping (BatteryRecorder) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
        observers.append((center, token))
    }
}
