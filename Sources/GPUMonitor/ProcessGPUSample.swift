import Foundation

struct ProcessGPUSample: Identifiable, Equatable {
    let pid: Int
    let name: String
    let gpuPercent: Double
    var id: Int { pid }
}

struct GPUSnapshot {
    let total: Double
    /// Empty when running without sudo (aggregate-only mode).
    let processes: [ProcessGPUSample]
    let timestamp: Date
}
