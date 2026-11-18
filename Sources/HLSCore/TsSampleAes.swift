import Foundation

/// Descifrado HLS SAMPLE-AES de un segmento MPEG-TS (port de TsSampleAes.kt). Se conservan los PID, la PAT/PMT,
/// el PCR y el resto de paquetes; solo se reescriben los PES de vídeo H.264 (0x1B / 0xDB) y audio AAC-ADTS (0x0F / 0xCF).
///
///  - Vídeo: en cada NAL de tipo 1 o 5 con más de 48 bytes, los primeros 32 son claros y después se cifra un bloque
///    de 16 de cada 160 (CBC encadenado entre los bloques cifrados; IV nuevo en cada NAL). Los bytes de escape del
///    NAL original van dentro del bloque cifrado: se quita el escape una vez, se descifra y NO se vuelve a escapar
///    (hacerlo añade un 03 de más y el decodificador falla).
///  - Audio: en cada trama ADTS van claros la cabecera (7 o 9 bytes) y los 16 siguientes; el resto, en bloques de 16
///    completos con CBC (IV nuevo en cada trama).
public enum TsSampleAes {
    private static let ts = 188

    /// Descifra un segmento completo. Devuelve nil si no es TS válido o no se entiende su estructura.
    public static func decrypt(_ data: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        guard data.count >= ts, data.count % ts == 0, data[0] == 0x47, key.count == 16, iv.count == 16 else { return nil }
        guard let types = streamTypes(data) else { return nil }
        let pmtPid = types.pmt
        let aes = AES128(key: key)
        var out = [UInt8](); out.reserveCapacity(data.count + 4096)
        var counters: [Int: Int] = [:]                          // contador de continuidad propio por PID

        // Paquetes de cada PES (desde un PUSI hasta el siguiente del mismo PID)
        let n = data.count / ts
        var lists: [(pid: Int, packets: [Int])] = []
        var firstOf: [Int: Int] = [:]                           // índice del primer paquete de un PES → posición en `lists`
        var skip = [Bool](repeating: false, count: n)           // paquetes de PES que no son el primero: los escribe el primero
        var open: [Int: Int] = [:]                              // PID → posición en `lists` del PES abierto
        for k in 0..<n {
            let o = k * ts
            let pid = pidOf(data, o)
            guard let t = types.map[pid], isVideo(t) || isAudio(t) else { continue }
            if data[o + 1] & 0x40 != 0 {
                lists.append((pid, [k])); open[pid] = lists.count - 1; firstOf[k] = lists.count - 1
            } else if let i = open[pid] { lists[i].packets.append(k); skip[k] = true }
        }

        for k in 0..<n {
            guard let idx = firstOf[k] else {
                if skip[k] { continue }
                var pkt = Array(data[(k * ts)..<(k * ts + ts)])
                if pidOf(pkt, 0) == pmtPid && pkt[1] & 0x40 != 0 { patchPmt(&pkt) }
                out += pkt; continue
            }
            let (pid, pk) = lists[idx]
            guard let pes = rebuild(data, pk, video: isVideo(types.map[pid]!), aes: aes, iv: iv) else { return nil }
            writePes(&out, pid: pid, data: data, first: k, pes: pes, counters: &counters)
        }
        return out
    }

    // SAMPLE-AES señala el H.264 cifrado como 0xDB y el AAC cifrado como 0xCF
    private static func isVideo(_ t: Int) -> Bool { t == 0x1b || t == 0xdb }
    private static func isAudio(_ t: Int) -> Bool { t == 0x0f || t == 0xcf }
    private static func pidOf(_ d: [UInt8], _ o: Int) -> Int { (Int(d[o + 1] & 0x1f) << 8) | Int(d[o + 2]) }

    /// Inicio de la carga útil de un paquete (tras el campo de adaptación, si lo hay).
    private static func payload(_ d: [UInt8], _ o: Int) -> Int {
        o + 4 + ((d[o + 3] >> 4) & 2 != 0 ? 1 + Int(d[o + 4]) : 0)
    }

    /// La PMT del segmento descifrado declara los tipos normales (H.264, AAC) y se rehace su CRC.
    private static func patchPmt(_ pkt: inout [UInt8]) {
        let pp = payload(pkt, 0)
        let b = pp + 1 + Int(pkt[pp])
        let len = (Int(pkt[b + 1] & 0x0f) << 8) | Int(pkt[b + 2])
        let progInfo = (Int(pkt[b + 10] & 0x0f) << 8) | Int(pkt[b + 11])
        var p = b + 12 + progInfo
        let end = b + 3 + len - 4
        while p + 5 <= end {
            if pkt[p] == 0xdb { pkt[p] = 0x1b } else if pkt[p] == 0xcf { pkt[p] = 0x0f }
            p += 5 + ((Int(pkt[p + 3] & 0x0f) << 8) | Int(pkt[p + 4]))
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for i in b..<end {
            crc ^= UInt32(pkt[i]) << 24
            for _ in 0..<8 { crc = (crc & 0x8000_0000 != 0) ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
        }
        for i in 0..<4 { pkt[end + i] = UInt8(truncatingIfNeeded: crc >> UInt32(24 - 8 * i)) }
    }

    /// PID → stream_type, leído de la PAT y la PMT del propio segmento (más el PID de la PMT).
    private static func streamTypes(_ d: [UInt8]) -> (map: [Int: Int], pmt: Int)? {
        var pmtPid = -1
        var res: [Int: Int] = [:]
        var o = 0
        while o + ts <= d.count {
            defer { o += ts }
            let pid = pidOf(d, o)
            if d[o + 1] & 0x40 == 0 { continue }
            let pp = payload(d, o)
            if pp >= o + ts { continue }
            if pid == 0 && pmtPid < 0 {
                let b = pp + 1 + Int(d[pp])
                let len = (Int(d[b + 1] & 0x0f) << 8) | Int(d[b + 2])
                var p = b + 8
                while p + 4 <= b + 3 + len - 4 {
                    let prog = (Int(d[p]) << 8) | Int(d[p + 1])
                    if prog != 0 { pmtPid = (Int(d[p + 2] & 0x1f) << 8) | Int(d[p + 3]); break }
                    p += 4
                }
            } else if pmtPid >= 0 && pid == pmtPid && res.isEmpty {
                let b = pp + 1 + Int(d[pp])
                let len = (Int(d[b + 1] & 0x0f) << 8) | Int(d[b + 2])
                let progInfo = (Int(d[b + 10] & 0x0f) << 8) | Int(d[b + 11])
                var p = b + 12 + progInfo
                let end = b + 3 + len - 4
                while p + 5 <= end {
                    res[(Int(d[p + 1] & 0x1f) << 8) | Int(d[p + 2])] = Int(d[p])
                    p += 5 + ((Int(d[p + 3] & 0x0f) << 8) | Int(d[p + 4]))
                }
            }
        }
        return res.isEmpty ? nil : (res, pmtPid)
    }

    /// PES completo (cabecera + ES ya descifrado) a partir de sus paquetes.
    private static func rebuild(_ d: [UInt8], _ pk: [Int], video: Bool, aes: AES128, iv: [UInt8]) -> [UInt8]? {
        var b = [UInt8]()
        for n in pk {
            let o = n * ts
            let afc = Int((d[o + 3] >> 4) & 3)
            if afc & 1 == 0 { continue }
            let start = o + 4 + (afc & 2 != 0 ? 1 + Int(d[o + 4]) : 0)
            if start < o + ts { b += d[start..<(o + ts)] }
        }
        guard b.count >= 9, b[0] == 0, b[1] == 0, b[2] == 1 else { return nil }
        let hdr = 9 + Int(b[8])
        guard hdr <= b.count else { return nil }
        let es = Array(b[hdr...])
        let dec = video ? decryptVideo(es, aes, iv) : decryptAudio(es, aes, iv)
        var res = Array(b[..<hdr]) + dec
        let oldLen = (Int(b[4]) << 8) | Int(b[5])
        let newLen = (oldLen == 0 || res.count - 6 > 0xffff) ? 0 : res.count - 6
        res[4] = UInt8(newLen >> 8); res[5] = UInt8(newLen & 0xff)
        return res
    }

    private static func decryptVideo(_ es: [UInt8], _ aes: AES128, _ iv: [UInt8]) -> [UInt8] {
        var starts: [Int] = []
        var j = 0
        while j + 3 <= es.count {
            if es[j] == 0 && es[j + 1] == 0 && es[j + 2] == 1 { starts.append(j); j += 3 } else { j += 1 }
        }
        if starts.isEmpty { return es }
        var out = Array(es[0..<starts[0]])
        for k in 0..<starts.count {
            let s = starts[k] + 3
            var e = k + 1 < starts.count ? starts[k + 1] : es.count
            var z = 0
            while k + 1 < starts.count && e > s && es[e - 1] == 0 { e -= 1; z += 1 }   // ceros que preceden al siguiente start code
            out += [0, 0, 1]
            let type = Int(es[s] & 0x1f)
            if (type == 1 || type == 5) && e - s > 48 {
                var raw = unescape(es, s, e)
                var pos = 32
                let dec = aes.cbcDecryptor(iv: iv)             // IV nuevo en cada NAL
                while pos + 16 <= raw.count { dec.update(&raw, start: pos, count: 16); pos += 160 }
                out += raw                                      // el cifrado se aplicó con los bytes de escape dentro: no se vuelven a escapar
            } else { out += es[s..<e] }
            out += [UInt8](repeating: 0, count: z)
        }
        return out
    }

    /// Quita los bytes de emulación (00 00 03 → 00 00).
    private static func unescape(_ d: [UInt8], _ s: Int, _ e: Int) -> [UInt8] {
        var o = [UInt8](); o.reserveCapacity(e - s)
        var zc = 0
        for i in s..<e {
            let b = d[i]
            if zc >= 2 && b == 3 { zc = 0; continue }
            o.append(b); zc = b == 0 ? zc + 1 : 0
        }
        return o
    }

    private static func decryptAudio(_ es: [UInt8], _ aes: AES128, _ iv: [UInt8]) -> [UInt8] {
        var out = es
        var i = 0
        while i + 7 <= out.count && out[i] == 0xff && out[i + 1] & 0xf0 == 0xf0 {
            let fl = (Int(out[i + 3] & 3) << 11) | (Int(out[i + 4]) << 3) | (Int(out[i + 5]) >> 5)
            if fl < 7 || i + fl > out.count { break }
            let clear = (out[i + 1] & 1 != 0 ? 7 : 9) + 16
            let n = (fl - clear) / 16
            if n > 0 { aes.cbcDecryptor(iv: iv).update(&out, start: i + clear, count: n * 16) }   // IV nuevo en cada trama
            i += fl
        }
        return out
    }

    /// Trocea un PES en paquetes TS: conserva el campo de adaptación (PCR…) del primero y rellena el último.
    private static func writePes(_ out: inout [UInt8], pid: Int, data d: [UInt8], first: Int, pes: [UInt8], counters: inout [Int: Int]) {
        let o = first * ts
        let afc = Int((d[o + 3] >> 4) & 3)
        var af: [UInt8]? = afc & 2 != 0 ? Array(d[(o + 5)..<(o + 5 + Int(d[o + 4]))]) : nil
        if af?.isEmpty == true { af = nil }
        var counter = counters[pid] ?? Int(d[o + 3] & 0x0f)
        var p = 0
        while p < pes.count {
            let body = af
            let space = body != nil ? 183 - body!.count : 184
            let take = min(space, pes.count - p)
            var pkt = [UInt8](repeating: 0, count: ts)
            pkt[0] = 0x47
            pkt[1] = UInt8((p == 0 ? 0x40 : 0) | (pid >> 8))
            pkt[2] = UInt8(pid & 0xff)
            var w = 4
            if body != nil || take < 184 {
                let afLen = 183 - take                           // bytes del campo de adaptación tras su longitud
                pkt[3] = UInt8(0x30 | (counter & 0x0f))
                pkt[4] = UInt8(afLen)
                if afLen > 0 {
                    if let bd = body { for (x, v) in bd.enumerated() { pkt[5 + x] = v } } else { pkt[5] = 0 }
                    let used = body?.count ?? 1
                    if 5 + used < 5 + afLen { for x in (5 + used)..<(5 + afLen) { pkt[x] = 0xff } }
                }
                w = 5 + afLen
            } else { pkt[3] = UInt8(0x10 | (counter & 0x0f)) }
            for x in 0..<take { pkt[w + x] = pes[p + x] }
            out += pkt
            p += take; counter = (counter + 1) & 0x0f; af = nil
        }
        counters[pid] = counter
    }

    /// DTS (o PTS si no hay) en 90 kHz del primer PES del segmento TS.
    public static func firstDts(_ d: [UInt8]) -> Int64? {
        var o = 0
        while o + ts <= d.count {
            defer { o += ts }
            if d[o + 1] & 0x40 == 0 { continue }
            let b = payload(d, o)
            if b + 19 > o + ts || d[b] != 0 || d[b + 1] != 0 || d[b + 2] != 1 { continue }
            let fl = Int((d[b + 7] >> 6) & 3)
            if fl == 0 { continue }
            func stamp(_ i: Int) -> Int64 {
                (Int64(d[i] & 0x0e) << 29) | (Int64(d[i + 1]) << 22) | (Int64(d[i + 2] & 0xfe) << 14) | (Int64(d[i + 3]) << 7) | (Int64(d[i + 4]) >> 1)
            }
            return fl == 3 ? stamp(b + 14) : stamp(b + 9)
        }
        return nil
    }
}
