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

    func testParamStructRoundTrip() throws {
        var p = SMCParamStruct()
        p.key = try fourCC("F0Tg")
        p.keyInfo_dataSize = 2
        p.keyInfo_dataType = try fourCC("fpe2")
        p.data8 = 6
        p.result = 0
        p.bytes[0] = 0x1F
        p.bytes[1] = 0x40
        let encoded = p.encode()
        XCTAssertEqual(encoded.count, 80)
        let decoded = SMCParamStruct.decode(encoded)
        XCTAssertEqual(decoded.key, p.key)
        XCTAssertEqual(decoded.keyInfo_dataSize, 2)
        XCTAssertEqual(fourCCString(decoded.keyInfo_dataType), "fpe2")
        XCTAssertEqual(decoded.data8, 6)
        XCTAssertEqual(decoded.bytes[0], 0x1F)
        XCTAssertEqual(decoded.bytes[1], 0x40)
    }

    // Every SMC integration path is gated on live hardware; run the CLI itself
    // for that. This suite pins the wire format that talks to AppleSMC.
}
