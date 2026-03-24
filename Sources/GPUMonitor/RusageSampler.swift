import Foundation
import IOKit

/// Samples per-process GPU time via AGXDeviceUserClient IOKit entries.
/// Each entry exposes accumulatedGPUTime (cumulative nanoseconds) per Metal command queue.
/// Does NOT require root.
final class RusageSampler {

    // entryID → sum of accumulatedGPUTime across all AppUsage contexts
    private var prevNs:   [UInt64: UInt64] = [:]
    private var prevDate  = Date()

    /// Returns [] on the first call (establishes baseline). Call once per second.
    func sample() -> [ProcessGPUSample] {
        let now      = Date()
        let elapsed  = now.timeIntervalSince(prevDate)
        guard elapsed >= 0.1 else { return [] }
        let intervalNs = elapsed * 1_000_000_000

        // ── Enumerate all AGXDeviceUserClient entries ──────────────────────────
        // These are user-client connection objects (IOKit !registered) so
        // IOServiceGetMatchingServices won't find them — must walk the full tree.
        var iterator: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                       IOOptionBits(kIORegistryIterateRecursively),
                                       &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        // entryID → (totalAccumulatedGPUNs, pid, processName)
        var curr: [UInt64: (ns: UInt64, pid: Int, name: String)] = [:]

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }

            // Skip anything that isn't an AGXDeviceUserClient
            var classBuf = [CChar](repeating: 0, count: 128)
            guard IOObjectGetClass(entry, &classBuf) == KERN_SUCCESS,
                  String(cString: classBuf) == "AGXDeviceUserClient" else { continue }

            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(entry, &entryID)

            var cfProps: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &cfProps,
                                                    kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = cfProps?.takeRetainedValue() as? [String: AnyObject]
            else { continue }

            // "IOUserClientCreator" = "pid 421, WindowServer"
            guard let creator = dict["IOUserClientCreator"] as? String else { continue }
            let (pid, name) = parseCreator(creator)
            guard pid > 0 else { continue }

            // "AppUsage" = [{"API"="Metal","accumulatedGPUTime"=83982641798791, ...}, ...]
            var totalNs: UInt64 = 0
            if let appUsage = dict["AppUsage"] as? NSArray {
                for ctx in appUsage {
                    if let ctxDict = ctx as? NSDictionary,
                       let v = ctxDict["accumulatedGPUTime"] as? NSNumber {
                        totalNs += v.uint64Value
                    }
                }
            }

            curr[entryID] = (ns: totalNs, pid: pid, name: name)
        }

        // ── Compute per-process deltas ─────────────────────────────────────────
        var pidDelta: [Int: (delta: UInt64, name: String)] = [:]
        for (id, c) in curr {
            guard let prevNs = prevNs[id], c.ns >= prevNs else { continue }
            let delta = c.ns - prevNs
            guard delta > 0 else { continue }
            pidDelta[c.pid, default: (0, c.name)].delta += delta
            pidDelta[c.pid]?.name = c.name      // keep name fresh
        }

        prevNs   = curr.mapValues(\.ns)
        prevDate = now

        return pidDelta.compactMap { pid, info in
            let pct = min(100.0, Double(info.delta) / intervalNs * 100.0)
            guard pct > 0.1 else { return nil }
            return ProcessGPUSample(pid: pid, name: info.name, gpuPercent: pct)
        }.sorted { $0.gpuPercent > $1.gpuPercent }
    }

    // MARK: - Helpers

    // "pid 421, WindowServer"  →  (421, "WindowServer")
    // "pid 421, com.apple.Foo" →  (421, "Foo")
    private func parseCreator(_ s: String) -> (Int, String) {
        let parts = s.components(separatedBy: ", ")
        guard parts.count >= 2,
              let pid = Int(parts[0].replacingOccurrences(of: "pid ", with: "").trimmingCharacters(in: .whitespaces))
        else { return (0, "") }
        let rawName = parts[1...].joined(separator: ", ")
        // Only strip dot-prefix for reverse-DNS bundle IDs (com.*, org.*, net.*, io.*, app.*)
        // Leave names like "python3.9" or "node.js" intact.
        let bundlePrefixes = ["com.", "org.", "net.", "io.", "app.", "co."]
        let name: String
        if bundlePrefixes.contains(where: { rawName.lowercased().hasPrefix($0) }) {
            name = rawName.components(separatedBy: ".").last ?? rawName
        } else {
            name = rawName
        }
        return (pid, name)
    }
}
