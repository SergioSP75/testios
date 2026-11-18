import XCTest
@testable import HLSCore

final class AESTests: XCTestCase {

    // Vector oficial FIPS-197: clave 00..0f, texto 00 11 22 .. ff → 69c4e0d8 6a7b0430 d8cdb780 70b4c55a
    private let key: [UInt8] = (0..<16).map { UInt8($0) }
    private let plain: [UInt8] = (0..<16).map { UInt8($0 * 0x11) }
    private let cipher: [UInt8] = [0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30,
                                   0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4, 0xc5, 0x5a]

    func testCifradoDeBloqueFIPS197() {
        XCTAssertEqual(SoftAES.shared.encryptBlock(plain, key: key), cipher)
    }

    func testDescifradoDeBloqueFIPS197() {
        XCTAssertEqual(SoftAES.shared.decryptBlock(cipher, key: key), plain)
    }

    func testCTRIdaYVuelta() {
        let aes = AES128(key: key)
        let iv = [UInt8](repeating: 7, count: 16)
        var data = (0..<100).map { UInt8($0) }
        let original = data
        aes.ctrDecryptor(iv: iv).update(&data, start: 0, count: 100)
        XCTAssertNotEqual(data, original)
        aes.ctrDecryptor(iv: iv).update(&data, start: 0, count: 100)   // CTR es simétrico
        XCTAssertEqual(data, original)
    }

    func testCTRPorTramosIgualQueDeUnaVez() {
        let aes = AES128(key: key)
        let iv = [UInt8](repeating: 3, count: 16)
        var a = (0..<70).map { UInt8($0) }
        var b = a
        aes.ctrDecryptor(iv: iv).update(&a, start: 0, count: 70)
        let d = aes.ctrDecryptor(iv: iv)
        d.update(&b, start: 0, count: 5); d.update(&b, start: 5, count: 33); d.update(&b, start: 38, count: 32)
        XCTAssertEqual(a, b)
    }

    func testCBCDescifra() {
        // Un bloque cifrado con IV cero: D(c) ^ 0 = plain
        var buf = cipher
        AES128(key: key).cbcDecryptor(iv: [UInt8](repeating: 0, count: 16)).update(&buf, start: 0, count: 16)
        XCTAssertEqual(buf, plain)
    }
}
