import Foundation
import IOKit

// Minimal AppleSMC user-client bridge. Read/write of 4-char SMC keys.
//
// The struct passed to IOConnectCallStructMethod must match the driver's
// SMCParamStruct byte for byte. Getting that layout wrong makes the driver
// reject the request, and one of the codes it can reject with is
// kIOReturnNotPrivileged even to a root caller -- so the "needs sudo" error
// was, historically, a symptom of a malformed struct rather than of missing
// privilege.
//
// The layout below uses Swift's natural struct alignment, which matches the
// C struct in Apple's original SMC sample. The proof it is right is that the
// sibling `monitor` project reads the SMC unprivileged with the same layout.
// Writes still require root -- that is a real privilege check the driver
// applies to write commands.

enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case ioFailed(kern_return_t)
    case notPrivileged
    case smcError(UInt8)
    case badKey(String)
    case badKeyType(String)
    case badSize(expected: Int, got: Int)

    var description: String {
        switch self {
        case .serviceNotFound: return "AppleSMC service not found"
        case .openFailed(let r): return "IOServiceOpen failed: 0x\(String(UInt32(bitPattern: r), radix: 16))"
        case .ioFailed(let r): return "IOConnectCallStructMethod failed: 0x\(String(UInt32(bitPattern: r), radix: 16))"
        case .notPrivileged: return "SMC access denied; re-run under sudo"
        case .smcError(0x84):
            // Verified on Mac17,3 (M5 Max, macOS 26.6.2): keyInfo on a key
            // that is not in the SMC's table (e.g. "XXXX", "F0Md") answers
            // result 0x84, while any real key answers 0.
            return "SMC returned error 0x84 (key not found)"
        case .smcError(let c): return "SMC returned error 0x\(String(c, radix: 16))"
        case .badKey(let k): return "SMC key must be 4 ASCII chars, got \(k.debugDescription)"
        case .badKeyType(let t): return "SMC key has unsupported type \(t.debugDescription)"
        case .badKey(let k): return "SMC key must be 4 ASCII chars, got \(k.debugDescription)"
        case .badSize(let e, let g): return "expected \(e) bytes, got \(g)"
        }
    }
}

private let kSMCHandleYPCEvent: UInt32 = 2

private let kSMCReadKey:    UInt8 = 5
private let kSMCWriteKey:   UInt8 = 6
private let kSMCGetKeyInfo: UInt8 = 9

// Must match the driver's SMCParamStruct byte for byte. Field names are the
// ones Apple uses in the original SMC sample so the layout can be checked
// against it. Swift's natural alignment lays these out at the same offsets
// as the C struct.
struct SMCParamStruct {
    var key: UInt32 = 0
    var versionMajor: UInt8 = 0
    var versionMinor: UInt8 = 0
    var versionBuild: UInt8 = 0
    var versionReserved: UInt8 = 0
    var versionRelease: UInt16 = 0
    var limitVersion: UInt16 = 0
    var limitLength: UInt16 = 0
    var limitCPU: UInt32 = 0
    var limitGPU: UInt32 = 0
    var limitMemory: UInt32 = 0
    var keyInfo = SMCKeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

struct SMCKeyInfo {
    var dataSize: IOByteCount32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

func fourCC(_ s: String) throws -> UInt32 {
    let bytes = Array(s.utf8)
    guard bytes.count == 4 else { throw SMCError.badKey(s) }
    return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) |
           (UInt32(bytes[2]) << 8)  |  UInt32(bytes[3])
}

func fourCCString(_ v: UInt32) -> String {
    let b = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
             UInt8((v >> 8)  & 0xFF), UInt8(v & 0xFF)]
    return String(bytes: b, encoding: .ascii) ?? "????"
}

private let kIOReturnNotPrivileged: kern_return_t = kern_return_t(bitPattern: 0xe00002c2)

final class SMC {
    private var conn: io_connect_t = 0

    init() throws {
        let svc = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard svc != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(svc) }
        let rc = IOServiceOpen(svc, mach_task_self_, 0, &conn)
        guard rc == kIOReturnSuccess else { throw SMCError.openFailed(rc) }
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    private func call(_ input: SMCParamStruct) throws -> SMCParamStruct {
        var input = input
        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let rc = IOConnectCallStructMethod(
            conn, kSMCHandleYPCEvent,
            &input, MemoryLayout<SMCParamStruct>.stride,
            &output, &outSize
        )
        if rc == kIOReturnNotPrivileged { throw SMCError.notPrivileged }
        guard rc == kIOReturnSuccess else { throw SMCError.ioFailed(rc) }
        if output.result != 0 { throw SMCError.smcError(output.result) }
        return output
    }

    private func keyInfo(_ key: String) throws -> (size: UInt32, type: UInt32) {
        var p = SMCParamStruct()
        p.key = try fourCC(key)
        p.data8 = kSMCGetKeyInfo
        let r = try call(p)
        return (r.keyInfo.dataSize, r.keyInfo.dataType)
    }

    func read(_ key: String) throws -> (bytes: [UInt8], type: String) {
        let info = try keyInfo(key)
        var p = SMCParamStruct()
        p.key = try fourCC(key)
        p.keyInfo.dataSize = info.size
        p.keyInfo.dataType = info.type
        p.data8 = kSMCReadKey
        let r = try call(p)
        let n = max(0, min(32, Int(info.size)))
        return (withUnsafeBytes(of: r.bytes) { Array($0.prefix(n)) },
                fourCCString(info.type))
    }

    func write(_ key: String, bytes: [UInt8]) throws {
        let info = try keyInfo(key)
        guard bytes.count == Int(info.size) else {
            throw SMCError.badSize(expected: Int(info.size), got: bytes.count)
        }
        var p = SMCParamStruct()
        p.key = try fourCC(key)
        p.keyInfo.dataSize = info.size
        p.keyInfo.dataType = info.type
        p.data8 = kSMCWriteKey
        withUnsafeMutableBytes(of: &p.bytes) { dst in
            for (i, b) in bytes.enumerated() where i < 32 { dst[i] = b }
        }
        _ = try call(p)
    }

    func readUInt8(_ key: String) throws -> UInt8 {
        let (b, _) = try read(key)
        guard b.count >= 1 else { throw SMCError.badSize(expected: 1, got: b.count) }
        return b[0]
    }

    // fpe2: 14-bit int, 2-bit fraction, big-endian. RPMs use it.
    func readFPE2(_ key: String) throws -> Double {
        let (b, _) = try read(key)
        guard b.count == 2 else { throw SMCError.badSize(expected: 2, got: b.count) }
        let raw = (UInt16(b[0]) << 8) | UInt16(b[1])
        return Double(raw) / 4.0
    }

    func writeFPE2(_ key: String, _ value: Double) throws {
        let cap = Double(UInt16.max) / 4.0
        let raw = UInt16(max(0.0, min(cap, value)) * 4.0)
        try write(key, bytes: [UInt8(raw >> 8), UInt8(raw & 0xFF)])
    }

    // "flt " is IEEE 754 float32, stored little-endian in the SMC's bytes buffer
    // on Apple Silicon. M-series Macs use this for F<n>Ac, F<n>Mn, F<n>Mx and
    // F<n>Tg; Intel Macs used fpe2 for the same keys.
    func readFLT(_ key: String) throws -> Double {
        let (b, _) = try read(key)
        guard b.count == 4 else { throw SMCError.badSize(expected: 4, got: b.count) }
        let raw = (UInt32(b[3]) << 24) | (UInt32(b[2]) << 16)
                | (UInt32(b[1]) << 8)  |  UInt32(b[0])
        return Double(Float(bitPattern: raw))
    }

    func writeFLT(_ key: String, _ value: Double) throws {
        let raw = Float(value).bitPattern
        try write(key, bytes: [
            UInt8( raw        & 0xFF),
            UInt8((raw >> 8)  & 0xFF),
            UInt8((raw >> 16) & 0xFF),
            UInt8((raw >> 24) & 0xFF),
        ])
    }

    // Read a fan-shaped float key without caring which encoding the machine uses.
    // Returns nil if the key is missing.
    func readFanFloat(_ key: String) throws -> Double? {
        do {
            let info = try keyInfoRaw(key)
            switch fourCCString(info.type) {
            case "flt ": return try readFLT(key)
            case "fpe2": return try readFPE2(key)
            default:     return nil
            }
        } catch SMCError.smcError(_) {
            return nil
        }
    }

    // Public keyInfo lookup for callers that want to dispatch by type.
    func keyInfoRaw(_ key: String) throws -> (size: UInt32, type: UInt32) {
        return try keyInfo(key)
    }

    // Write a fan target/mode float value using whichever encoding the machine
    // uses for this key. Throws SMCError.badKeyType if the type is neither.
    func writeFan(_ key: String, _ value: Double) throws {
        let info = try keyInfo(key)
        switch fourCCString(info.type) {
        case "flt ": try writeFLT(key, value)
        case "fpe2": try writeFPE2(key, value)
        default:     throw SMCError.badKeyType(fourCCString(info.type))
        }
    }
}
