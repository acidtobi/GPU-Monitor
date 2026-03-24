import Foundation
import IOKit
import CoreGraphics

final class GPUDataSource: ObservableObject {

    static let maxTrackedProcesses = 20
    static let windowMs = 120_000  // 2 minutes in ms

    /// Sample interval in milliseconds (100…2000, step 100).
    @Published var sampleIntervalMs: Int = 1000

    /// Chronological buffer of all snapshots within the last windowMs milliseconds.
    @Published private(set) var history: [GPUSnapshot] = []
    @Published private(set) var current: Double = 0
    @Published private(set) var gpuName: String = "GPU"
    @Published private(set) var permissionDenied = false

    // Stable top-process list for chart rendering (updated each sample)
    @Published private(set) var topProcessNames: [String] = []

    private var stopped = false
    private var colorIndex: [String: Int] = [:]   // process name → palette index
    private var nextColorIndex = 0
    private let rusage = RusageSampler()

    init() {
        gpuName = detectGPUName()
        Task { await samplingLoop() }
    }

    func stop() { stopped = true }

    // MARK: - Color assignment

    func colorIndex(for name: String) -> Int {
        if let idx = colorIndex[name] { return idx }
        let idx = nextColorIndex % ChartPalette.colors.count
        colorIndex[name] = idx
        nextColorIndex += 1
        return idx
    }

    // MARK: - Sampling loop

    private func samplingLoop() async {
        while !stopped {
            let start = ContinuousClock.now

            // IOKit aggregate is always authoritative for the total %.
            let total     = queryAggregateGPU()
            // Per-process GPU ns via Mach task_info(TASK_POWER_INFO_V2).
            // Works without root for same-user processes; works for all processes as root.
            let processes = rusage.sample()
            let snap = GPUSnapshot(total: total, processes: processes, timestamp: Date())
            await push(snap)

            let elapsed   = start.duration(to: .now)
            let remaining = Duration.milliseconds(sampleIntervalMs) - elapsed
            if remaining > .zero {
                try? await Task.sleep(for: remaining)
            }
        }
    }

    @MainActor
    private func push(_ snap: GPUSnapshot) {
        current = snap.total
        let cutoff = snap.timestamp.addingTimeInterval(-Double(Self.windowMs) / 1000.0)
        history.append(snap)
        history.removeAll { $0.timestamp < cutoff }

        // Rebuild topProcessNames from the full 2-minute history window
        var scores: [String: Double] = [:]
        for s in history {
            for p in s.processes { scores[p.name, default: 0] += p.gpuPercent }
        }
        let sorted = scores.sorted { $0.value > $1.value }
            .prefix(Self.maxTrackedProcesses)
            .map(\.key)
        // Assign colors to any newly seen processes
        for name in snap.processes.map(\.name) { _ = colorIndex(for: name) }
        topProcessNames = sorted
    }

    // MARK: - IOKit aggregate fallback

    private func queryAggregateGPU() -> Double {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOAccelerator")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }

        var maxUsage: Double = 0
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let u = gpuUsageFromEntry(entry) { maxUsage = max(maxUsage, u) }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return maxUsage
    }

    private func gpuUsageFromEntry(_ entry: io_object_t) -> Double? {
        var cfProps: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &cfProps, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = cfProps?.takeRetainedValue() as? [String: AnyObject],
              let stats = props["PerformanceStatistics"] as? [String: AnyObject] else { return nil }
        if let v = stats["GPU Activity(%)"]    as? NSNumber { return v.doubleValue }
        if let v = stats["Device Utilization %"] as? NSNumber { return v.doubleValue }
        if let v = stats["utilization"]          as? NSNumber { return v.doubleValue }
        for (key, val) in stats where key.lowercased().contains("util") {
            if let v = val as? NSNumber { return v.doubleValue }
        }
        return nil
    }

    // MARK: - GPU name

    private func detectGPUName() -> String {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOAccelerator")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return "GPU" }
        defer { IOObjectRelease(iterator) }
        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return "GPU" }
        defer { IOObjectRelease(entry) }
        var parent: io_object_t = 0
        if IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS {
            defer { IOObjectRelease(parent) }
            var buf = [CChar](repeating: 0, count: 128)
            if IORegistryEntryGetName(parent, &buf) == KERN_SUCCESS {
                let name = String(cString: buf)
                if !name.isEmpty && name != "Root" { return name }
            }
        }
        var buf = [CChar](repeating: 0, count: 128)
        if IORegistryEntryGetName(entry, &buf) == KERN_SUCCESS {
            let name = String(cString: buf)
            if !name.isEmpty { return name }
        }
        return "GPU"
    }
}

// MARK: - Palette

enum ChartPalette {
    static let colors: [CGColor] = [
        // vibrant, accessible set
        hex(0x4C9BE8),   // blue
        hex(0x5BC471),   // green
        hex(0xF0943A),   // orange
        hex(0xC46BE8),   // purple
        hex(0xE8564A),   // red
        hex(0x3FD4C4),   // teal
        hex(0xF2D63A),   // yellow
        hex(0xE87DC4),   // pink
    ]

    private static func hex(_ v: UInt32) -> CGColor {
        let r = CGFloat((v >> 16) & 0xFF) / 255
        let g = CGFloat((v >>  8) & 0xFF) / 255
        let b = CGFloat( v        & 0xFF) / 255
        return CGColor(red: r, green: g, blue: b, alpha: 1)
    }
}
