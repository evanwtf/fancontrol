import Foundation
import IOKit

// Minimal AppleSMC user-client bridge. Read/write of 4-char SMC keys.
// Writes always require root. On Apple Silicon, most reads do too --
// IOConnectCallStructMethod returns kIOReturnNotPrivileged (0xe00002c2)
// to non-root callers.

enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case ioFailed(kern_return_t)
    case notPrivileged
    case smcError(UInt8)
    case badKey(String)
    case badSize(expected: Int, got: Int)

    var description: String {
        switch self {
        case .serviceNotFound: return "AppleSMC service not found"
        case .openFailed(let r): return "IOServiceOpen failed: 0x\(String(UInt32(bitPattern: r), radix: 16))"
        case .ioFailed(let r): return "IOConnectCallStructMethod failed: 0x\(String(UInt32(bitPattern: r), radix: 16))"
        case .notPrivileged: return "SMC access denied; re-run under sudo"
        case .smcError(let c): return "SMC returned error 0x\(String(c, radix: 16))"
        case .badKey(let k): return "SMC key must be 4 ASCII chars, got \(k.debugDescription)"
        case .badSize(let e, let g): return "expected \(e) bytes, got \(g)"
        }
    }
}

private let kSMCHandleYPCEvent: UInt32 = 2

private let kSMCReadKey:    UInt8 = 5
private let kSMCWriteKey:   UInt8 = 6
private let kSMCGetKeyInfo: UInt8 = 9

// AppleSMC's SMCParamStruct is 80 bytes. Its multi-byte fields sit at
// offsets that are not naturally aligned, so we encode and decode with
// byte-wise memory copies (via loadUnaligned/withUnsafeBytes).
struct SMCParamStruct {
    var key: UInt32 = 0
    var vers0: UInt8 = 0
    var vers1: UInt8 = 0
    var vers2: UInt8 = 0
    var vers3: UInt8 = 0
    var vers4: UInt16 = 0
    var pLimit0: UInt16 = 0
    var pLimit1: UInt16 = 0
    var pLimit2: UInt16 = 0
    var pLimit3: UInt16 = 0
    var keyInfo_dataSize: UInt32 = 0
    var keyInfo_dataType: UInt32 = 0
    var keyInfo_dataAttributes: UInt8 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: [UInt8] = Array(repeating: 0, count: 32)

    func encode() -> Data {
        var d = Data(count: 80)
        d.withUnsafeMutableBytes { raw -> Void in
            let base = raw.baseAddress!
            func put<T>(_ value: T, at offset: Int) {
                _ = withUnsafeBytes(of: value) { src in
                    memcpy(base.advanced(by: offset), src.baseAddress, MemoryLayout<T>.size)
                }
            }
            put(key.bigEndian, at: 0)
            put(vers0, at: 4)
            put(vers1, at: 5)
            put(vers2, at: 6)
            put(vers3, at: 7)
            put(vers4, at: 8)
            put(pLimit0, at: 10)
            put(pLimit1, at: 12)
            put(pLimit2, at: 14)
            put(pLimit3, at: 16)
            put(keyInfo_dataSize.bigEndian, at: 18)
            put(keyInfo_dataType.bigEndian, at: 22)
            put(keyInfo_dataAttributes, at: 26)
            put(result, at: 30)
            put(status, at: 31)
            put(data8, at: 32)
            put(data32.bigEndian, at: 34)
            for i in 0..<32 { put(bytes[i], at: 40 + i) }
        }
        return d
    }

    static func decode(_ d: Data) -> SMCParamStruct {
        var s = SMCParamStruct()
        d.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            func get<T>(_ type: T.Type, at offset: Int) -> T {
                return base.advanced(by: offset).loadUnaligned(as: type)
            }
            s.key = UInt32(bigEndian: get(UInt32.self, at: 0))
            s.keyInfo_dataSize = UInt32(bigEndian: get(UInt32.self, at: 18))
            s.keyInfo_dataType = UInt32(bigEndian: get(UInt32.self, at: 22))
            s.keyInfo_dataAttributes = get(UInt8.self, at: 26)
            s.result = get(UInt8.self, at: 30)
            s.status = get(UInt8.self, at: 31)
            s.data8 = get(UInt8.self, at: 32)
            s.data32 = UInt32(bigEndian: get(UInt32.self, at: 34))
            for i in 0..<32 { s.bytes[i] = get(UInt8.self, at: 40 + i) }
        }
        return s
    }
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
        let inBytes = input.encode()
        var outBytes = Data(count: 80)
        var outSize: size_t = 80
        let rc = inBytes.withUnsafeBytes { inPtr -> kern_return_t in
            outBytes.withUnsafeMutableBytes { outPtr -> kern_return_t in
                IOConnectCallStructMethod(
                    conn,
                    kSMCHandleYPCEvent,
                    inPtr.baseAddress, 80,
                    outPtr.baseAddress, &outSize
                )
            }
        }
        if rc == kIOReturnNotPrivileged { throw SMCError.notPrivileged }
        guard rc == kIOReturnSuccess else { throw SMCError.ioFailed(rc) }
        let out = SMCParamStruct.decode(outBytes)
        if out.result != 0 { throw SMCError.smcError(out.result) }
        return out
    }

    private func keyInfo(_ key: String) throws -> (size: UInt32, type: UInt32) {
        var p = SMCParamStruct()
        p.key = try fourCC(key)
        p.data8 = kSMCGetKeyInfo
        let r = try call(p)
        return (r.keyInfo_dataSize, r.keyInfo_dataType)
    }

    func read(_ key: String) throws -> (bytes: [UInt8], type: String) {
        let info = try keyInfo(key)
        var p = SMCParamStruct()
        p.key = try fourCC(key)
        p.keyInfo_dataSize = info.size
        p.keyInfo_dataType = info.type
        p.data8 = kSMCReadKey
        let r = try call(p)
        let n = Int(info.size)
        return (Array(r.bytes.prefix(n)), fourCCString(info.type))
    }

    func write(_ key: String, bytes: [UInt8]) throws {
        let info = try keyInfo(key)
        guard bytes.count == Int(info.size) else {
            throw SMCError.badSize(expected: Int(info.size), got: bytes.count)
        }
        var p = SMCParamStruct()
        p.key = try fourCC(key)
        p.keyInfo_dataSize = info.size
        p.keyInfo_dataType = info.type
        p.data8 = kSMCWriteKey
        for (i, b) in bytes.enumerated() where i < 32 { p.bytes[i] = b }
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
}
