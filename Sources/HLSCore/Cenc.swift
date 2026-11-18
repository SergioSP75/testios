import Foundation

/// Port de Cenc.kt. Quita el cifrado CENC (AES-CTR) o CBCS (AES-CBC por patrón) de vídeo fMP4,
/// para que AVPlayer reciba segmentos ya limpios desde el relay local.
///  - `cleanInit`: el segmento de inicio deja de anunciar cifrado (encv/enca → formato original).
///  - `decryptSegment`: descifra en el sitio las muestras de cada fragmento (moof + mdat).
/// Los tamaños de las cajas no cambian: lo que sobra se convierte en cajas «free».
public enum Cenc {

    /// Caja MP4: tipo, posición, tamaño y tamaño de la cabecera.
    public struct Box {
        public let type: String
        public let start: Int
        public let size: Int
        public let header: Int
        public var bodyStart: Int { start + header }
        public var end: Int { start + size }
    }

    /// Parámetros de cifrado de la pista (caja `tenc`).
    public struct Tenc {
        public let scheme: String?
        public let crypt: Int
        public let skip: Int
        public let ivSize: Int
        public let constIv: [UInt8]?
    }

    // MARK: - Lectura de cajas

    public static func u32(_ b: [UInt8], _ p: Int) -> Int {
        Int(b[p]) << 24 | Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3])
    }
    static func u16(_ b: [UInt8], _ p: Int) -> Int { Int(b[p]) << 8 | Int(b[p + 1]) }
    static func u64(_ b: [UInt8], _ p: Int) -> Int {
        var v = 0
        for i in 0..<8 { v = v << 8 | Int(b[p + i]) }
        return v
    }
    static func fourcc(_ b: [UInt8], _ p: Int) -> String {
        String(bytes: b[p..<(p + 4)], encoding: .isoLatin1) ?? ""
    }

    public static func boxes(_ b: [UInt8], from: Int, to: Int) -> [Box] {
        var out: [Box] = []
        var p = from
        while p + 8 <= to {
            var size = u32(b, p)
            var hs = 8
            if size == 1 && p + 16 <= to { size = u64(b, p + 8); hs = 16 }
            else if size == 0 { size = to - p }
            if size < hs || p + size > to { break }
            out.append(Box(type: fourcc(b, p + 4), start: p, size: size, header: hs))
            p += size
        }
        return out
    }

    static func setType(_ b: inout [UInt8], at: Int, _ type: String) {
        let t = Array(type.utf8)
        for i in 0..<4 { b[at + 4 + i] = t[i] }
    }

    public static func isInit(_ b: [UInt8]) -> Bool { boxes(b, from: 0, to: b.count).contains { $0.type == "moov" } }
    public static func isMedia(_ b: [UInt8]) -> Bool { boxes(b, from: 0, to: b.count).contains { $0.type == "moof" } }

    /// Posición de la primera aparición de una etiqueta de 4 letras (a partir del byte 4), o -1.
    static func find(_ b: [UInt8], _ tag: String) -> Int {
        let t = Array(tag.utf8)
        if b.count < t.count + 4 { return -1 }
        var i = 4
        while i <= b.count - t.count {
            if b[i] == t[0] && b[i + 1] == t[1] && b[i + 2] == t[2] && b[i + 3] == t[3] { return i }
            i += 1
        }
        return -1
    }

    // MARK: - Segmento de inicio

    /// Esquema que declara el inicio (`cenc` = AES-CTR, `cbcs` = AES-CBC por patrón); nil si va en claro.
    public static func scheme(_ initSeg: [UInt8]) -> String? {
        let i = find(initSeg, "schm")
        return (i > 0 && i + 12 <= initSeg.count) ? fourcc(initSeg, i + 8) : nil
    }

    /// Identificador de clave (KID, hexadecimal) de la pista, leído de su caja `tenc`.
    public static func kid(_ initSeg: [UInt8]) -> String? {
        let i = find(initSeg, "tenc")
        if i < 0 || i + 28 > initSeg.count { return nil }
        return initSeg[(i + 12)..<(i + 28)].map { String(format: "%02x", $0) }.joined()
    }

    public static func tenc(_ initSeg: [UInt8]) -> Tenc? {
        let i = find(initSeg, "tenc")
        if i < 0 || i + 28 > initSeg.count { return nil }
        let pattern = Int(initSeg[i + 9])
        let v1 = initSeg[i + 4] != 0
        let ivSize = Int(initSeg[i + 11])
        var const: [UInt8]?
        if ivSize == 0 && i + 29 <= initSeg.count {
            let n = Int(initSeg[i + 28])
            if n > 0 && i + 29 + n <= initSeg.count { const = Array(initSeg[(i + 29)..<(i + 29 + n)]) }
        }
        return Tenc(scheme: scheme(initSeg), crypt: v1 ? pattern >> 4 : 0, skip: v1 ? pattern & 15 : 0,
                    ivSize: ivSize, constIv: const)
    }

    /// Copia del inicio sin la señalización de cifrado.
    public static func cleanInit(_ initSeg: [UInt8]) -> [UInt8] {
        var b = initSeg
        func walk(_ from: Int, _ to: Int) {
            for box in boxes(b, from: from, to: to) {
                switch box.type {
                case "moov", "trak", "mdia", "minf", "stbl":
                    walk(box.bodyStart, box.end)
                case "pssh":
                    setType(&b, at: box.start, "free")
                case "stsd":
                    walk(box.bodyStart + 8, box.end)        // versión/flags + nº de entradas
                case "encv", "enca":
                    let skip = box.type == "encv" ? 78 : audioEntryHeader(b, box)
                    let kids = boxes(b, from: box.bodyStart + skip, to: box.end)
                    guard let sinf = kids.first(where: { $0.type == "sinf" }) else { continue }
                    if let frma = boxes(b, from: sinf.bodyStart, to: sinf.end).first(where: { $0.type == "frma" }) {
                        setType(&b, at: box.start, fourcc(b, frma.bodyStart))
                    }
                    setType(&b, at: sinf.start, "free")
                default: break
                }
            }
        }
        walk(0, b.count)
        return b
    }

    private static func audioEntryHeader(_ b: [UInt8], _ box: Box) -> Int {
        switch u16(b, box.bodyStart + 8) {
        case 1: return 28 + 16
        case 2: return 28 + 36
        default: return 28
        }
    }

    // MARK: - Segmentos de vídeo/audio

    private struct Sample { let iv: [UInt8]; let subs: [(Int, Int)] }

    private static let piffSenc: [UInt8] = [0xA2, 0x39, 0x4F, 0x52, 0x5A, 0x9B, 0x4F, 0x14,
                                            0xA2, 0x44, 0x6C, 0x42, 0x7C, 0x64, 0x8D, 0xF4]

    private static func isPiffSenc(_ b: [UInt8], _ box: Box) -> Bool {
        box.type == "uuid" && box.size >= box.header + 16 + 8
            && Array(b[box.bodyStart..<(box.bodyStart + 16)]) == piffSenc
    }

    /// Descifra `seg` en el sitio con `key` (16 bytes). Devuelve cuántas muestras descifró.
    /// Con `cbcs` se usa AES-CBC por patrón; sin él, AES-CTR (`cenc`).
    @discardableResult
    public static func decryptSegment(_ seg: inout [UInt8], key: [UInt8], cbcs: Tenc? = nil) throws -> Int {
        let aes = AES128(key: key)
        var samples = 0
        for moof in boxes(seg, from: 0, to: seg.count).filter({ $0.type == "moof" }) {
            for traf in boxes(seg, from: moof.bodyStart, to: moof.end).filter({ $0.type == "traf" }) {
                let kids = boxes(seg, from: traf.bodyStart, to: traf.end)
                guard let tfhd = kids.first(where: { $0.type == "tfhd" }) else { continue }
                // CMAF/DASH/HLS usan «senc»; Smooth Streaming (PIFF) lo mete en una caja «uuid»
                var sencBox = kids.first(where: { $0.type == "senc" })
                if sencBox == nil, let u = kids.first(where: { isPiffSenc(seg, $0) }) {
                    sencBox = Box(type: "senc", start: u.start, size: u.size, header: u.header + 16)
                }
                guard let senc = sencBox else { continue }

                var p = tfhd.bodyStart
                let tf = u32(seg, p) & 0xFFFFFF; p += 8                     // versión/flags + track_ID
                if tf & 0x1 != 0 { p += 8 }
                if tf & 0x2 != 0 { p += 4 }
                if tf & 0x8 != 0 { p += 4 }
                let defSize = tf & 0x10 != 0 ? u32(seg, p) : 0

                let (ivSize, entries) = try parseSenc(seg, senc, forcedIv: cbcs?.ivSize)
                var si = 0
                for trun in kids.filter({ $0.type == "trun" }) {
                    var q = trun.bodyStart
                    let f = u32(seg, q) & 0xFFFFFF; q += 4
                    let n = u32(seg, q); q += 4
                    var dataOff = 0
                    if f & 0x1 != 0 { dataOff = Int(Int32(truncatingIfNeeded: u32(seg, q))); q += 4 }
                    if f & 0x4 != 0 { q += 4 }
                    var pos = moof.start + dataOff
                    for _ in 0..<n {
                        if f & 0x100 != 0 { q += 4 }
                        var size = defSize
                        if f & 0x200 != 0 { size = u32(seg, q); q += 4 }
                        if f & 0x400 != 0 { q += 4 }
                        if f & 0x800 != 0 { q += 4 }
                        if si < entries.count {
                            let e = entries[si]; si += 1
                            var iv = [UInt8](repeating: 0, count: 16)
                            if let c = cbcs, ivSize == 0, let ci = c.constIv {
                                for i in 0..<min(16, ci.count) { iv[i] = ci[i] }
                            } else {
                                for i in 0..<min(ivSize, e.iv.count) { iv[i] = e.iv[i] }
                            }
                            if let c = cbcs {
                                // El encadenado CBC se reinicia con el IV al empezar cada submuestra
                                var ranges: [(Int, Int)] = []
                                if e.subs.isEmpty { ranges = [(pos, size)] }
                                else {
                                    var r = pos
                                    for (clear, prot) in e.subs { r += clear; ranges.append((r, prot)); r += prot }
                                }
                                for (start, len) in ranges {
                                    let dec = aes.cbcDecryptor(iv: iv)
                                    cbcsRange(dec, &seg, start: start, len: len, crypt: c.crypt, skip: c.skip)
                                }
                            } else if e.subs.isEmpty {
                                aes.ctrDecryptor(iv: iv).update(&seg, start: pos, count: size)
                            } else {
                                // Un solo descifrador por muestra: el flujo de clave sigue entre submuestras
                                let dec = aes.ctrDecryptor(iv: iv)
                                var r = pos
                                for (clear, prot) in e.subs {
                                    r += clear
                                    dec.update(&seg, start: r, count: prot)
                                    r += prot
                                }
                            }
                            samples += 1
                        }
                        pos += size
                    }
                }
                // Ya no hay nada cifrado: la información auxiliar sobra
                for k in kids {
                    let aux = k.type == "senc" || k.type == "saiz" || k.type == "saio" || isPiffSenc(seg, k)
                    let seig = (k.type == "sbgp" || k.type == "sgpd") && k.start + 16 <= seg.count
                        && fourcc(seg, k.start + 12) == "seig"
                    if aux || seig { setType(&seg, at: k.start, "free") }
                }
            }
        }
        return samples
    }

    /// Descifra un rango con el patrón cbcs: `crypt` bloques cifrados y `skip` en claro; el resto parcial queda en claro.
    private static func cbcsRange(_ dec: AES128.CBCDecryptor, _ b: inout [UInt8], start: Int, len: Int, crypt: Int, skip: Int) {
        if crypt == 0 && skip == 0 {
            let n = len & ~15
            if n > 0 { dec.update(&b, start: start, count: n) }
            return
        }
        var p = start
        var left = len
        while left >= 16 {
            let blocks = min(crypt, left / 16)
            dec.update(&b, start: p, count: blocks * 16)
            let step = (crypt + skip) * 16
            p += step; left -= step
        }
    }

    /// El tamaño del IV (8 o 16) no va en el fragmento: se deduce probando cuál hace cuadrar la caja.
    private static func parseSenc(_ b: [UInt8], _ senc: Box, forcedIv: Int?) throws -> (Int, [Sample]) {
        var p = senc.bodyStart
        let flags = u32(b, p) & 0xFFFFFF; p += 4
        if flags & 0x1 != 0 { p += 20 }          // PIFF: algoritmo + tamaño de IV + KID propios del fragmento
        let count = u32(b, p); p += 4
        let candidates = forcedIv != nil ? [forcedIv!] : [8, 16]
        for ivSize in candidates {
            var q = p
            var out: [Sample] = []
            var ok = true
            for _ in 0..<count {
                if q + ivSize > senc.end { ok = false; break }
                let iv = Array(b[q..<(q + ivSize)]); q += ivSize
                var subs: [(Int, Int)] = []
                if flags & 0x2 != 0 {
                    if q + 2 > senc.end { ok = false; break }
                    let n = u16(b, q); q += 2
                    if q + 6 * n > senc.end { ok = false; break }
                    for _ in 0..<n { subs.append((u16(b, q), u32(b, q + 2))); q += 6 }
                }
                out.append(Sample(iv: iv, subs: subs))
            }
            if ok && q == senc.end { return (ivSize, out) }
        }
        throw NSError(domain: "Cenc", code: 1, userInfo: [NSLocalizedDescriptionKey: "senc: el tamaño del IV no cuadra"])
    }
}
