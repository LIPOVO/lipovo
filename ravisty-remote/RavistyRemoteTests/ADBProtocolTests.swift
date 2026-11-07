import XCTest
@testable import RavistyRemote

final class ADBProtocolTests: XCTestCase {
    func testPacketRoundTripAndChecksum() throws {
        let packet = ADBPacket(command: ADBCommand.open, arg0: 7, payload: Data("shell:input keyevent 3\0".utf8))
        let bytes = packet.encoded()
        let header = Data(bytes.prefix(24))
        let body = Data(bytes.dropFirst(24))
        let decoded = try ADBPacket.decode(header: header, payload: body)
        XCTAssertEqual(decoded.command, ADBCommand.open)
        XCTAssertEqual(decoded.arg0, 7)
        XCTAssertEqual(decoded.arg1, 0)
        XCTAssertEqual(decoded.payload, packet.payload)
        XCTAssertEqual(header.uint32LE(at: 16), body.reduce(UInt32(0)) { $0 &+ UInt32($1) })
    }

    func testRejectsBadMagicAndPayload() throws {
        var bytes = ADBPacket(command: ADBCommand.write, arg0: 1, arg1: 2, payload: Data([1, 2, 3])).encoded()
        bytes[20] ^= 0xff
        XCTAssertThrowsError(try ADBPacket.payloadLength(header: Data(bytes.prefix(24))))
        let good = ADBPacket(command: ADBCommand.write, payload: Data([1, 2, 3])).encoded()
        XCTAssertThrowsError(try ADBPacket.decode(header: Data(good.prefix(24)), payload: Data([1, 2, 4])))
        XCTAssertThrowsError(try ADBPacket.payloadLength(header: Data([0, 1])))
    }

    func testRejectsOversizePayload() {
        var header = Data()
        [ADBCommand.write, 1, 2, UInt32(ADBPacket.maxPayload + 1), 0, ADBCommand.write ^ 0xffffffff]
            .forEach { header.appendLE($0) }
        XCTAssertThrowsError(try ADBPacket.payloadLength(header: header))
    }

    func testAndroidPublicKeyMontgomeryFields() throws {
        // N = 2^2048 - 159 => R mod N = 159; R² mod N = 25281.
        let modulus = [UInt8(0)] + [UInt8](repeating: 255, count: 255) + [UInt8(97)]
        let body = [UInt8(2), 0x82, 0x01, 0x01] + modulus + [2, 3, 1, 0, 1]
        let der = Data([0x30, 0x82, 0x01, 0x0a] + body)
        let encoded = try AndroidRSAPublicKey.encode(pkcs1: der)
        XCTAssertEqual(encoded.count, 524)
        XCTAssertEqual(encoded.uint32LE(at: 0), 64)
        XCTAssertEqual(encoded.uint32LE(at: 8), 0xffffff61)
        XCTAssertEqual(encoded.uint32LE(at: 4) &* encoded.uint32LE(at: 8), UInt32.max)
        XCTAssertEqual(encoded.uint32LE(at: 264), 25281)
        XCTAssertEqual(Array(encoded[268..<520]), [UInt8](repeating: 0, count: 252))
        XCTAssertEqual(encoded.uint32LE(at: 520), 65537)
    }

    func testPNGPrefixRemovalDoesNotRewritePNGBytes() throws {
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82]
                       + [UInt8](repeating: 0, count: 20))
        let raw = Data("Init wrapper\nopen mma dev failed\n".utf8) + png
        XCTAssertEqual(try PNGResponse.clean(raw), png)
        XCTAssertThrowsError(try PNGResponse.clean(Data("Not a PNG".utf8)))
    }

    func testPublicKeyWithDenseModulusCarries() throws {
        var modulus = (0..<256).map { UInt8(($0 * 73 + 41) & 255) }
        modulus[0] |= 0x80
        modulus[255] |= 1
        let integer = [UInt8(0)] + modulus
        let body = [UInt8(2), 0x82, 0x01, 0x01] + integer + [2, 3, 1, 0, 1]
        let key = try AndroidRSAPublicKey.encode(pkcs1: Data([0x30, 0x82, 0x01, 0x0a] + body))
        XCTAssertEqual(key.uint32LE(at: 4), 0xa3c413df)
        XCTAssertEqual(key.uint32LE(at: 264), 0x91d3a837)
        XCTAssertEqual(key.uint32LE(at: 268), 0xb11f5508)
        XCTAssertEqual(key.uint32LE(at: 264 + 31 * 4), 0xe5380bcb)
        XCTAssertEqual(key.uint32LE(at: 264 + 63 * 4), 0x990257c7)
    }
}
