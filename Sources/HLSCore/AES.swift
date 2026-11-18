import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// AES-128 para descifrar vídeo (CENC = CTR, CBCS = CBC) y HLS SAMPLE-AES.
///
/// En iPhone se usa CommonCrypto (acelerado por hardware). En Windows/Linux, donde no existe,
/// se usa una versión en Swift puro: más lenta, pero permite probar el código fuera del Mac.
public struct AES128 {
    private let key: [UInt8]

    public init(key: [UInt8]) {
        precondition(key.count == 16, "La clave AES debe tener 16 bytes")
        self.key = key
    }

    // MARK: - CTR (cenc)

    /// Descifrador CTR que conserva el contador y el desfase dentro del bloque entre llamadas
    /// (las submuestras de un mismo sample siguen el mismo flujo de clave, byte a byte).
    public final class CTRDecryptor {
        private let key: [UInt8]
        #if canImport(CommonCrypto)
        private var cryptor: CCCryptorRef?
        init(key: [UInt8], iv: [UInt8]) {
            self.key = key
            CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                    CCPadding(ccNoPadding), iv, key, 16, nil, 0, 0,
                                    CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
        }
        deinit { if let c = cryptor { CCCryptorRelease(c) } }
        /// Descifra `count` bytes de `buf` desde `start`, en el sitio.
        public func update(_ buf: inout [UInt8], start: Int, count: Int) {
            guard let c = cryptor, count > 0 else { return }
            buf.withUnsafeMutableBytes { raw in
                let p = raw.baseAddress!.advanced(by: start)
                var moved = 0
                CCCryptorUpdate(c, p, count, p, count, &moved)
            }
        }
        #else
        private var counter: [UInt8]
        private var ks = [UInt8](repeating: 0, count: 16)
        private var used = 16                 // bytes del bloque de clave ya gastados (16 = hay que generar otro)
        init(key: [UInt8], iv: [UInt8]) { self.key = key; self.counter = iv }
        public func update(_ buf: inout [UInt8], start: Int, count: Int) {
            for i in 0..<count {
                if used == 16 {
                    ks = SoftAES.shared.encryptBlock(counter, key: key)
                    var k = 15
                    while k >= 0 { counter[k] &+= 1; if counter[k] != 0 { break }; k -= 1 }
                    used = 0
                }
                buf[start + i] ^= ks[used]; used += 1
            }
        }
        #endif
    }

    public func ctrDecryptor(iv: [UInt8]) -> CTRDecryptor { CTRDecryptor(key: key, iv: iv) }

    // MARK: - CBC sin relleno

    /// Descifrador CBC que conserva el encadenado entre llamadas (para el patrón de cbcs y SAMPLE-AES).
    public final class CBCDecryptor {
        private let key: [UInt8]
        private var prev: [UInt8]
        init(key: [UInt8], iv: [UInt8]) { self.key = key; self.prev = iv }

        /// Descifra `count` bytes (múltiplo de 16) de `buf` desde `start`, en el sitio.
        public func update(_ buf: inout [UInt8], start: Int, count: Int) {
            #if canImport(CommonCrypto)
            let ivCopy = prev
            // Último bloque cifrado → IV de la siguiente llamada
            if count >= 16 { prev = Array(buf[(start + count - 16)..<(start + count)]) }
            var out = [UInt8](repeating: 0, count: count)
            var moved = 0
            let st = buf.withUnsafeBytes { src in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0 /* sin relleno */,
                        key, 16, ivCopy, src.baseAddress!.advanced(by: start), count, &out, count, &moved)
            }
            if st == kCCSuccess { for i in 0..<count { buf[start + i] = out[i] } }
            #else
            var i = 0
            while i + 16 <= count {
                let block = Array(buf[(start + i)..<(start + i + 16)])
                let plain = SoftAES.shared.decryptBlock(block, key: key)
                for j in 0..<16 { buf[start + i + j] = plain[j] ^ prev[j] }
                prev = block
                i += 16
            }
            #endif
        }
    }

    public func cbcDecryptor(iv: [UInt8]) -> CBCDecryptor { CBCDecryptor(key: key, iv: iv) }
}

// MARK: - AES en Swift puro (solo se usa donde no hay CommonCrypto)

final class SoftAES {
    static let shared = SoftAES()

    private var sbox = [UInt8](repeating: 0, count: 256)
    private var inv = [UInt8](repeating: 0, count: 256)

    private init() {
        // Generar la caja S: inverso multiplicativo en GF(2^8) + transformación afín
        var p: UInt8 = 1, q: UInt8 = 1
        repeat {
            p = p ^ (p << 1) ^ ((p & 0x80) != 0 ? 0x1B : 0)          // p *= 3
            q ^= q << 1; q ^= q << 2; q ^= q << 4                       // q /= 3
            if q & 0x80 != 0 { q ^= 0x09 }
            let x = q ^ rotl(q, 1) ^ rotl(q, 2) ^ rotl(q, 3) ^ rotl(q, 4)
            sbox[Int(p)] = x ^ 0x63
        } while p != 1
        sbox[0] = 0x63
        for i in 0..<256 { inv[Int(sbox[i])] = UInt8(i) }
    }

    private func rotl(_ x: UInt8, _ n: UInt8) -> UInt8 { (x << n) | (x >> (8 - n)) }
    private func xtime(_ x: UInt8) -> UInt8 { (x << 1) ^ ((x & 0x80) != 0 ? 0x1B : 0) }
    private func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var a = a, b = b, r: UInt8 = 0
        while b != 0 { if b & 1 != 0 { r ^= a }; a = xtime(a); b >>= 1 }
        return r
    }

    /// Expansión de la clave: 11 claves de ronda de 16 bytes.
    private func expand(_ key: [UInt8]) -> [[UInt8]] {
        var w = [[UInt8]](repeating: [0, 0, 0, 0], count: 44)
        for i in 0..<4 { w[i] = Array(key[(4 * i)..<(4 * i + 4)]) }
        var rcon: UInt8 = 1
        for i in 4..<44 {
            var t = w[i - 1]
            if i % 4 == 0 {
                t = [sbox[Int(t[1])] ^ rcon, sbox[Int(t[2])], sbox[Int(t[3])], sbox[Int(t[0])]]
                rcon = xtime(rcon)
            }
            w[i] = (0..<4).map { w[i - 4][$0] ^ t[$0] }
        }
        return (0..<11).map { r in (0..<4).flatMap { w[4 * r + $0] } }
    }

    func encryptBlock(_ block: [UInt8], key: [UInt8]) -> [UInt8] {
        let rk = expand(key)
        var s = (0..<16).map { block[$0] ^ rk[0][$0] }
        for round in 1...10 {
            s = s.map { sbox[Int($0)] }
            // ShiftRows (estado en columnas: índice = 4*col + fila)
            var t = s
            for c in 0..<4 { for r in 0..<4 { t[4 * c + r] = s[4 * ((c + r) % 4) + r] } }
            s = t
            if round != 10 {
                for c in 0..<4 {
                    let a = Array(s[(4 * c)..<(4 * c + 4)])
                    s[4 * c]     = xtime(a[0]) ^ (xtime(a[1]) ^ a[1]) ^ a[2] ^ a[3]
                    s[4 * c + 1] = a[0] ^ xtime(a[1]) ^ (xtime(a[2]) ^ a[2]) ^ a[3]
                    s[4 * c + 2] = a[0] ^ a[1] ^ xtime(a[2]) ^ (xtime(a[3]) ^ a[3])
                    s[4 * c + 3] = (xtime(a[0]) ^ a[0]) ^ a[1] ^ a[2] ^ xtime(a[3])
                }
            }
            s = (0..<16).map { s[$0] ^ rk[round][$0] }
        }
        return s
    }

    func decryptBlock(_ block: [UInt8], key: [UInt8]) -> [UInt8] {
        let rk = expand(key)
        var s = (0..<16).map { block[$0] ^ rk[10][$0] }
        for round in stride(from: 9, through: 0, by: -1) {
            // InvShiftRows
            var t = s
            for c in 0..<4 { for r in 0..<4 { t[4 * ((c + r) % 4) + r] = s[4 * c + r] } }
            s = t.map { inv[Int($0)] }
            s = (0..<16).map { s[$0] ^ rk[round][$0] }
            if round != 0 {
                for c in 0..<4 {
                    let a = Array(s[(4 * c)..<(4 * c + 4)])
                    s[4 * c]     = mul(a[0], 14) ^ mul(a[1], 11) ^ mul(a[2], 13) ^ mul(a[3], 9)
                    s[4 * c + 1] = mul(a[0], 9) ^ mul(a[1], 14) ^ mul(a[2], 11) ^ mul(a[3], 13)
                    s[4 * c + 2] = mul(a[0], 13) ^ mul(a[1], 9) ^ mul(a[2], 14) ^ mul(a[3], 11)
                    s[4 * c + 3] = mul(a[0], 11) ^ mul(a[1], 13) ^ mul(a[2], 9) ^ mul(a[3], 14)
                }
            }
        }
        return s
    }
}
