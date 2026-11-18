import Foundation

// Escritura de cajas MP4 (ISO BMFF) para HLS fMP4: inicio (ftyp+moov) y fragmentos (moof+mdat). Lo usa MkvToHls.

/// Una muestra (trama) de un fragmento.
struct Mp4Sample {
    var data: [UInt8]
    var duration: UInt32
    var sync: Bool
    var compositionOffset: Int32 = 0
}

enum Mp4 {
    // MARK: Bytes

    static func u16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    static func u32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    static func i32(_ v: Int32) -> [UInt8] { u32(UInt32(bitPattern: v)) }
    static func u64(_ v: UInt64) -> [UInt8] { u32(UInt32(v >> 32)) + u32(UInt32(v & 0xFFFF_FFFF)) }
    static func fourCC(_ s: String) -> [UInt8] { Array(s.utf8.prefix(4)) }

    static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] { u32(UInt32(8 + payload.count)) + fourCC(type) + payload }
    static func full(_ type: String, version: UInt8 = 0, flags: UInt32 = 0, _ payload: [UInt8]) -> [UInt8] {
        box(type, [version, UInt8((flags >> 16) & 0xFF), UInt8((flags >> 8) & 0xFF), UInt8(flags & 0xFF)] + payload)
    }

    static let identityMatrix: [UInt8] = u32(0x00010000) + u32(0) + u32(0) + u32(0) + u32(0x00010000) + u32(0) + u32(0) + u32(0) + u32(0x40000000)

    // MARK: Inicio (init segment)

    enum Kind { case video(width: Int, height: Int), audio }

    /// ftyp + moov de una pista con la entrada de muestras `sampleEntry` (avc1, hvc1, mp4a, ac-3, ec-3…).
    static func initSegment(trackId: Int, kind: Kind, timescale: UInt32, language: String, sampleEntry: [UInt8]) -> [UInt8] {
        let ftyp = box("ftyp", fourCC("iso6") + u32(1) + fourCC("iso6") + fourCC("cmfc") + fourCC("mp41"))
        let mvhd = full("mvhd", u32(0) + u32(0) + u32(1000) + u32(0) + u32(0x00010000) + u16(0x0100) + [UInt8](repeating: 0, count: 10)
                        + identityMatrix + [UInt8](repeating: 0, count: 24) + u32(UInt32(trackId + 1)))
        var w = 0, h = 0, isVideo = false
        if case .video(let ww, let hh) = kind { w = ww; h = hh; isVideo = true }
        let tkhd = full("tkhd", flags: 3, u32(0) + u32(0) + u32(UInt32(trackId)) + u32(0) + u32(0) + [UInt8](repeating: 0, count: 8)
                        + u16(0) + u16(0) + u16(isVideo ? 0 : 0x0100) + u16(0) + identityMatrix + u32(UInt32(w) << 16) + u32(UInt32(h) << 16))
        let mdhd = full("mdhd", u32(0) + u32(0) + u32(timescale) + u32(0) + u16(packedLanguage(language)) + u16(0))
        let hdlr = full("hdlr", u32(0) + fourCC(isVideo ? "vide" : "soun") + [UInt8](repeating: 0, count: 12) + Array((isVideo ? "VideoHandler" : "SoundHandler").utf8) + [0])
        let media = isVideo ? full("vmhd", flags: 1, u16(0) + [UInt8](repeating: 0, count: 6)) : full("smhd", u16(0) + u16(0))
        let dinf = box("dinf", full("dref", u32(1) + full("url ", flags: 1, [])))
        let stbl = box("stbl", full("stsd", u32(1) + sampleEntry) + full("stts", u32(0)) + full("stsc", u32(0)) + full("stsz", u32(0) + u32(0)) + full("stco", u32(0)))
        let trak = box("trak", tkhd + box("mdia", mdhd + hdlr + box("minf", media + dinf + stbl)))
        let mvex = box("mvex", full("trex", u32(UInt32(trackId)) + u32(1) + u32(0) + u32(0) + u32(0)))
        return ftyp + box("moov", mvhd + trak + mvex)
    }

    /// Código de idioma ISO-639-2 (3 letras) empaquetado en 15 bits.
    static func packedLanguage(_ l: String) -> Int {
        let s = Array(l.lowercased().utf8)
        guard s.count == 3, s.allSatisfy({ $0 >= 97 && $0 <= 122 }) else { return 0x55C4 }       // «und»
        return (Int(s[0] - 0x60) << 10) | (Int(s[1] - 0x60) << 5) | Int(s[2] - 0x60)
    }

    // MARK: Entradas de muestras

    /// avc1 / hvc1: `config` es el registro avcC / hvcC tal cual lo guarda MKV en CodecPrivate.
    static func videoEntry(hevc: Bool, width: Int, height: Int, config: [UInt8], colr: (p: Int, t: Int, m: Int, full: Bool)?) -> [UInt8] {
        var body = [UInt8](repeating: 0, count: 6) + u16(1) + u16(0) + u16(0) + [UInt8](repeating: 0, count: 12)
        body += u16(width) + u16(height) + u32(0x00480000) + u32(0x00480000) + u32(0) + u16(1)
        body += [UInt8](repeating: 0, count: 32) + u16(0x18) + u16(0xFFFF)
        body += box(hevc ? "hvcC" : "avcC", config)
        if let c = colr { body += box("colr", fourCC("nclx") + u16(c.p) + u16(c.t) + u16(c.m) + [c.full ? 0x80 : 0]) }
        return box(hevc ? "hvc1" : "avc1", body)
    }

    /// Entrada de audio: `type` = mp4a / ac-3 / ec-3 y `config` = la caja hija (esds / dac3 / dec3) ya construida.
    static func audioEntry(type: String, channels: Int, sampleRate: Int, config: [UInt8]) -> [UInt8] {
        var body = [UInt8](repeating: 0, count: 6) + u16(1) + [UInt8](repeating: 0, count: 8)
        body += u16(max(channels, 1)) + u16(16) + u16(0) + u16(0) + u32(UInt32(min(sampleRate, 65535)) << 16)
        return box(type, body + config)
    }

    /// esds con la configuración AudioSpecificConfig de AAC.
    static func esds(asc: [UInt8], bitrate: UInt32 = 0) -> [UInt8] {
        func desc(_ tag: UInt8, _ p: [UInt8]) -> [UInt8] { [tag, 0x80, 0x80, 0x80, UInt8(p.count)] + p }
        let dsi = desc(0x05, asc)
        let dec = desc(0x04, [0x40, 0x15] + [0, 0, 0] + u32(bitrate) + u32(bitrate) + dsi)
        let sl = desc(0x06, [0x02])
        return full("esds", desc(0x03, u16(1) + [0] + dec + sl))
    }

    // MARK: Fragmentos

    /// moof + mdat con las muestras. `baseTime` en la escala de tiempo de la pista. Vídeo lleva banderas y desfase de composición por muestra.
    static func fragment(sequence: Int, trackId: Int, baseTime: UInt64, samples: [Mp4Sample], video: Bool) -> [UInt8] {
        let mfhd = full("mfhd", u32(UInt32(sequence)))
        // tfhd: base de datos = el moof; en audio, banderas por defecto «muestra de sincronía»
        let tfhd = video ? full("tfhd", flags: 0x020000, u32(UInt32(trackId))) : full("tfhd", flags: 0x020020, u32(UInt32(trackId)) + u32(0x02000000))
        let tfdt = full("tfdt", version: 1, u64(baseTime))
        func trun(offset: Int32) -> [UInt8] {
            var p = u32(UInt32(samples.count)) + i32(offset)
            for s in samples {
                p += u32(s.duration) + u32(UInt32(s.data.count))
                if video { p += u32(s.sync ? 0x02000000 : 0x01010000) + i32(s.compositionOffset) }
            }
            return full("trun", version: 0, flags: video ? 0x000F01 : 0x000301, p)
        }
        let probe = box("moof", mfhd + box("traf", tfhd + tfdt + trun(offset: 0)))
        let moof = box("moof", mfhd + box("traf", tfhd + tfdt + trun(offset: Int32(probe.count + 8))))
        var mdat = u32(UInt32(8 + samples.reduce(0) { $0 + $1.data.count })) + fourCC("mdat")
        for s in samples { mdat += s.data }
        return moof + mdat
    }
}

// MARK: - Cadenas de códecs y datos de audio

/// Lectura de bits (MSB primero) para las cabeceras de AC-3 y E-AC-3.
struct BitReader {
    let b: [UInt8]; var pos = 0
    init(_ b: [UInt8]) { self.b = b }
    mutating func read(_ n: Int) -> Int {
        var v = 0
        for _ in 0..<n {
            let byte = pos >> 3
            let bit = byte < b.count ? Int((b[byte] >> UInt8(7 - (pos & 7))) & 1) : 0
            v = (v << 1) | bit; pos += 1
        }
        return v
    }
}

enum CodecStrings {
    /// «avc1.640028» desde el registro avcC.
    static func avc(_ avcC: [UInt8]) -> String {
        guard avcC.count >= 4 else { return "avc1.640028" }
        return "avc1." + String(format: "%02x%02x%02x", avcC[1], avcC[2], avcC[3])
    }

    /// «hvc1.2.4.L120.B0» desde el registro hvcC (perfil, compatibilidad, nivel y restricciones).
    static func hevc(_ c: [UInt8]) -> String {
        guard c.count >= 13 else { return "hvc1.2.4.L120.B0" }
        let space = Int(c[1] >> 6), tier = (c[1] >> 5) & 1, profile = Int(c[1] & 0x1F)
        var compat = UInt32(c[2]) << 24 | UInt32(c[3]) << 16 | UInt32(c[4]) << 8 | UInt32(c[5])
        var rev: UInt32 = 0
        for _ in 0..<32 { rev = (rev << 1) | (compat & 1); compat >>= 1 }
        var cons = Array(c[6..<12])
        while cons.count > 1, cons.last == 0 { cons.removeLast() }
        let spaceStr = space == 0 ? "" : String(UnicodeScalar(UInt8(64 + space)))
        return "hvc1.\(spaceStr)\(profile).\(String(rev, radix: 16)).\(tier == 1 ? "H" : "L")\(c[12])." + cons.map { String($0, radix: 16, uppercase: true) }.joined(separator: ".")
    }

    /// AudioSpecificConfig de AAC → «mp4a.40.2» y frecuencia.
    static func aac(_ asc: [UInt8]) -> (codec: String, rate: Int) {
        guard asc.count >= 2 else { return ("mp4a.40.2", 48000) }
        var br = BitReader(asc)
        var aot = br.read(5); if aot == 31 { aot = 32 + br.read(6) }
        let idx = br.read(4)
        let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let rate = idx == 15 ? br.read(24) : (idx < rates.count ? rates[idx] : 48000)
        return ("mp4a.40.\(aot)", rate)
    }

    /// Primera trama AC-3 → caja dac3 (3 bytes) o nil si no es AC-3.
    static func dac3(frame f: [UInt8]) -> [UInt8]? {
        guard f.count > 8, f[0] == 0x0B, f[1] == 0x77 else { return nil }
        var br = BitReader(Array(f[4...]))
        let fscod = br.read(2), frmsizecod = br.read(6), bsid = br.read(5), bsmod = br.read(3), acmod = br.read(3)
        if (acmod & 1) != 0 && acmod != 1 { _ = br.read(2) }
        if (acmod & 4) != 0 { _ = br.read(2) }
        if acmod == 2 { _ = br.read(2) }
        let lfe = br.read(1)
        let code = frmsizecod >> 1
        let v = (fscod << 22) | (bsid << 17) | (bsmod << 14) | (acmod << 11) | (lfe << 10) | (code << 5)
        return [UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    /// Primera trama E-AC-3 → caja dec3 y su frecuencia/bloques, o nil si no lo es.
    static func dec3(frame f: [UInt8]) -> (box: [UInt8], rate: Int, blocks: Int)? {
        guard f.count > 8, f[0] == 0x0B, f[1] == 0x77 else { return nil }
        var br = BitReader(Array(f[2...]))
        _ = br.read(2); _ = br.read(3)
        let frmsiz = br.read(11)
        var fscod = br.read(2)
        var numblks = 6
        var rate = 48000
        if fscod == 3 { let f2 = br.read(2); rate = [24000, 22050, 16000, 0][f2]; fscod = 3 }
        else { rate = [48000, 44100, 32000][fscod]; numblks = [1, 2, 3, 6][br.read(2)] }
        let acmod = br.read(3), lfe = br.read(1), bsid = br.read(5)
        let bytes = (frmsiz + 1) * 2
        let dataRate = rate > 0 ? bytes * 8 * rate / (numblks * 256) / 1000 : 0
        var bits: [Int] = []                       // data_rate(13) num_ind_sub(3) fscod(2) bsid(5) res(1) asvc(1) bsmod(3) acmod(3) lfeon(1) res(3) num_dep_sub(4) res(1)
        func put(_ v: Int, _ n: Int) { for i in stride(from: n - 1, through: 0, by: -1) { bits.append((v >> i) & 1) } }
        put(dataRate, 13); put(0, 3); put(min(fscod, 2), 2); put(bsid, 5); put(0, 1); put(0, 1); put(0, 3); put(acmod, 3); put(lfe, 1); put(0, 3); put(0, 4); put(0, 1)
        var out: [UInt8] = []
        for i in stride(from: 0, to: bits.count, by: 8) { var v = 0; for j in 0..<8 { v = (v << 1) | (i + j < bits.count ? bits[i + j] : 0) }; out.append(UInt8(v)) }
        return (out, rate, numblks)
    }
}
