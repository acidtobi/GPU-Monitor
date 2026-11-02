import Foundation
import IOKit

/// Reads keys from the System Management Controller through the AppleSMC user client.
/// Does NOT require root. Only `flt ` keys are supported, which is what Apple Silicon uses for power.
final class SMC {

    // Offsets into the 80-byte SMCKeyData struct the kernel expects (C layout):
    // key u32 @0, version @4, power limits @12, keyInfo { dataSize u32 @28, dataType u32 @32 },
    // result u8 @40, status u8 @41, command u8 @42, data32 u32 @44, bytes [32] @48.
    private static let structSize = 80
    private static let keyOffset = 0
    private static let dataSizeOffset = 28
    private static let dataTypeOffset = 32
    private static let resultOffset = 40
    private static let commandOffset = 42
    private static let bytesOffset = 48

    private static let handleYPCEvent: UInt32 = 2
    private static let readBytes: UInt8 = 5
    private static let readKeyInfo: UInt8 = 9
    static let floatType = fourCC("flt ")

    private var connection: io_connect_t = 0
    /// dataSize and dataType per key; nil for keys this Mac doesn't have.
    private var info: [UInt32: (size: UInt32, type: UInt32)?] = [:]

    /// nil if the SMC can't be opened.
    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit { IOServiceClose(connection) }

    /// Value of a `flt ` key, e.g. "PSTR". nil if the key is missing, of another type, or not finite.
    func float(_ key: String) -> Float? {
        let code = Self.fourCC(key)
        guard let (size, type) = keyInfo(code), type == Self.floatType, size == 4 else { return nil }
        var input = Self.request(code, command: Self.readBytes)
        input.store(size, at: Self.dataSizeOffset)
        guard let out = call(input) else { return nil }
        let value = out.load(Float.self, at: Self.bytesOffset)  // little-endian, like the host
        return value.isFinite ? value : nil
    }

    static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    // MARK: - Private

    private func keyInfo(_ code: UInt32) -> (UInt32, UInt32)? {
        if let cached = info[code] { return cached }
        var result: (UInt32, UInt32)?
        if let out = call(Self.request(code, command: Self.readKeyInfo)) {
            result = (out.load(UInt32.self, at: Self.dataSizeOffset), out.load(UInt32.self, at: Self.dataTypeOffset))
        }
        info[code] = .some(result)
        return result
    }

    private static func request(_ code: UInt32, command: UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: structSize)
        bytes.store(code, at: keyOffset)
        bytes[commandOffset] = command
        return bytes
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: Self.structSize)
        var outputSize = Self.structSize
        let kr = input.withUnsafeBytes { inBuf in
            output.withUnsafeMutableBytes { outBuf in
                IOConnectCallStructMethod(connection, Self.handleYPCEvent,
                                          inBuf.baseAddress, Self.structSize, outBuf.baseAddress, &outputSize)
            }
        }
        guard kr == KERN_SUCCESS, output[Self.resultOffset] == 0 else { return nil }
        return output
    }
}

private extension Array where Element == UInt8 {
    mutating func store<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        withUnsafeMutableBytes { $0.storeBytes(of: value, toByteOffset: offset, as: T.self) }
    }

    func load<T>(_ type: T.Type, at offset: Int) -> T {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
    }
}
