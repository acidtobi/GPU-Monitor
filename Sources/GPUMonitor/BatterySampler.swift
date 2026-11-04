import Foundation
import IOKit

/// One recorded battery tick. These values are what BatteryStore persists.
struct BatterySample: Equatable {
    let timestamp: Date
    /// State of charge, 0…100.
    let chargePct: Double
    /// Total system power draw in watts. nil when the Mac doesn't report it.
    let systemPowerW: Double?
    /// Battery power in watts: positive while charging, negative while discharging.
    let batteryPowerW: Double?
    /// True while a power adapter is connected. nil when unknown (history recorded before v2).
    let acPower: Bool?
}

/// Charger state shown next to the live values. Not recorded.
struct BatteryStatus: Equatable {
    let externalConnected: Bool
    let isCharging: Bool
    let fullyCharged: Bool
}

struct BatteryReading: Equatable {
    let sample: BatterySample
    let status: BatteryStatus
}

/// Reads charge and charger state from the AppleSmartBattery IORegistry entry and power from the
/// SMC. The IORegistry only refreshes about once a minute; the SMC power keys update every second.
/// Does NOT require root.
final class BatterySampler {

    private let smc = SMC()

    /// Returns nil on Macs without a battery.
    func sample(at timestamp: Date = Date()) -> BatteryReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        // The real level in mAh (Apple Silicon). CurrentCapacity is the rounded UI value and can
        // read 100 while the battery is at 98.6 %.
        // Without it, CurrentCapacity / MaxCapacity: a percentage on Apple Silicon, mAh on Intel.
        let current = number(service, "AppleRawCurrentCapacity") ?? number(service, "CurrentCapacity")
        let max = number(service, "AppleRawMaxCapacity") ?? number(service, "MaxCapacity")
        guard let current = current?.doubleValue, let max = max?.doubleValue, max > 0 else { return nil }
        let chargePct = min(100, Swift.max(0, current / max * 100))

        let status = BatteryStatus(
            externalConnected: bool(service, "ExternalConnected"),
            isCharging:        bool(service, "IsCharging"),
            fullyCharged:      bool(service, "FullyCharged")
        )

        // SBAP: battery power in W, positive while discharging (= -B0AC × B0AV).
        // Fallback: Voltage in mV × InstantAmperage in mA (signed, negative = discharging).
        // Negative amperage can come back as a huge unsigned value; int64Value restores the sign.
        var batteryPowerW = smc?.float("SBAP").map { -Double($0) }
        if batteryPowerW == nil,
           let mV = number(service, "Voltage")?.int64Value,
           let mA = (number(service, "InstantAmperage") ?? number(service, "Amperage"))?.int64Value {
            batteryPowerW = Double(mV) * Double(mA) / 1_000_000
        }

        // PSTR: total system draw in W. Fallback: "PowerTelemetryData" = {"SystemLoad"=18613, ...} in mW.
        var systemPowerW = smc?.float("PSTR").map { Double($0) }
        if systemPowerW == nil,
           let telemetry = property(service, "PowerTelemetryData") as? [String: AnyObject],
           let load = telemetry["SystemLoad"] as? NSNumber {
            systemPowerW = load.doubleValue / 1000
        } else if systemPowerW == nil, !status.externalConnected, let b = batteryPowerW {
            // Fallback (older/Intel Macs): on battery the system runs entirely off the battery.
            systemPowerW = Swift.max(0, -b)
        }

        return BatteryReading(
            sample: BatterySample(timestamp: timestamp,
                                  chargePct: chargePct,
                                  systemPowerW: systemPowerW,
                                  batteryPowerW: batteryPowerW,
                                  acPower: status.externalConnected),
            status: status
        )
    }

    // MARK: - Helpers

    private func property(_ service: io_service_t, _ key: String) -> AnyObject? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    private func number(_ service: io_service_t, _ key: String) -> NSNumber? {
        property(service, key) as? NSNumber
    }

    private func bool(_ service: io_service_t, _ key: String) -> Bool {
        (property(service, key) as? NSNumber)?.boolValue ?? false
    }
}
