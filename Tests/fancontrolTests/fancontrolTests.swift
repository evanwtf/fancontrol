import XCTest
@testable import fancontrol

final class FanControlTests: XCTestCase {

    func testFourCCRoundTrip() throws {
        let v = try fourCC("F0Md")
        XCTAssertEqual(fourCCString(v), "F0Md")
    }

    func testFourCCRejectsWrongLength() {
        XCTAssertThrowsError(try fourCC("FNu"))
        XCTAssertThrowsError(try fourCC("FNumX"))
    }

    // The struct passed to IOConnectCallStructMethod must be exactly 80 bytes.
    // Swift's natural alignment is what makes that hold; a field added or
    // reordered can silently shift every offset the driver reads.
    func testParamStructSizeIs80() {
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.size, 80)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.stride, 80)
    }

    // Assign every field the CLI sets before an SMC call and read it back --
    // proves the struct is usable end-to-end without touching the driver.
    // The driver contract itself is exercised by running the CLI against real
    // hardware, since there is no simulator for AppleSMC.
    func testParamStructRoundTrip() throws {
        var p = SMCParamStruct()
        p.key = try fourCC("F0Tg")
        p.keyInfo.dataSize = 2
        p.keyInfo.dataType = try fourCC("fpe2")
        p.data8 = 6
        p.result = 0
        withUnsafeMutableBytes(of: &p.bytes) { $0[0] = 0x1F; $0[1] = 0x40 }
        XCTAssertEqual(p.key, try fourCC("F0Tg"))
        XCTAssertEqual(p.keyInfo.dataSize, 2)
        XCTAssertEqual(fourCCString(p.keyInfo.dataType), "fpe2")
        XCTAssertEqual(p.data8, 6)
        withUnsafeBytes(of: p.bytes) {
            XCTAssertEqual($0[0], 0x1F)
            XCTAssertEqual($0[1], 0x40)
        }
    }

    // The fan mode key is lowercase on Apple Silicon. Enumerating the live SMC
    // key table on Mac17,3 (M5 Max, macOS 26.6.2) found "F0md"/"F1md" (ui8,
    // size 1) and no "F0Md" -- keyInfo on the uppercase spelling returns 0x84,
    // key not found, which is what `max` died on. smcFanControl's Intel-era
    // spelling was "F<n>Md". Read and write paths must both go through this
    // list so they cannot drift apart again.
    func testModeKeyCandidates() {
        XCTAssertEqual(modeKeyCandidates(0), ["F0md", "F0Md"])
        XCTAssertEqual(modeKeyCandidates(3), ["F3md", "F3Md"])
    }

    // Every SMC integration path is gated on live hardware; run the CLI itself
    // for that. This suite pins the wire format that talks to AppleSMC.
}
