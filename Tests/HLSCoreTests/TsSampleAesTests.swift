import XCTest
@testable import HLSCore

/// Segmento TS sintético cifrado con SAMPLE-AES: se cifra aquí con las reglas del formato y se comprueba
/// que el descifrador devuelve exactamente los bytes originales (vídeo H.264 y audio ADTS).
final class TsSampleAesTests: XCTestCase {
    let key = [UInt8](0..<16), iv = [UInt8](repeating: 7, count: 16)
    let videoPid = 0x100, audioPid = 0x101, pmtPid = 0x20

    /// CBC encadenado: cada bloque cifrado alimenta al siguiente (igual que lo descifra el reproductor).
    func encryptBlocks(_ buf: inout [UInt8], at positions: [Int]) {
        var prev = iv
        for p in positions {
            let plain = Array(buf[p..<(p + 16)])
            let c = SoftAES.shared.encryptBlock((0..<16).map { plain[$0] ^ prev[$0] }, key: key)
            for i in 0..<16 { buf[p + i] = c[i] }
            prev = c
        }
    }

    func section(_ body: [UInt8]) -> [UInt8] {         // pointer_field + sección rellenada hasta 184 bytes
        var s: [UInt8] = [0] + body
        s += [UInt8](repeating: 0xff, count: 184 - s.count); return s
    }
    func packet(pid: Int, pusi: Bool, cc: Int, payload: [UInt8]) -> [UInt8] {
        var p: [UInt8] = [0x47, UInt8((pusi ? 0x40 : 0) | (pid >> 8)), UInt8(pid & 0xff), UInt8(0x10 | cc)]
        p += payload; return p
    }
    /// PES troceado en paquetes TS (el último con relleno en el campo de adaptación).
    func packets(pid: Int, pes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []; var p = 0; var cc = 0
        while p < pes.count {
            let take = min(184, pes.count - p)
            var pkt: [UInt8] = [0x47, UInt8((p == 0 ? 0x40 : 0) | (pid >> 8)), UInt8(pid & 0xff)]
            if take < 184 {
                let afLen = 183 - take
                pkt += [UInt8(0x30 | cc), UInt8(afLen)]
                if afLen > 0 { pkt += [0] + [UInt8](repeating: 0xff, count: afLen - 1) }
            } else { pkt += [UInt8(0x10 | cc)] }
            pkt += pes[p..<(p + take)]
            out += pkt; p += take; cc = (cc + 1) & 15
        }
        return out
    }
    func pes(_ id: UInt8, _ es: [UInt8]) -> [UInt8] {
        let len = es.count + 3
        return [0, 0, 1, id, UInt8(len >> 8), UInt8(len & 0xff), 0x80, 0, 0] + es
    }
    /// Carga útil concatenada de un PID (para comparar PES antes y después).
    func extract(_ ts: [UInt8], pid: Int) -> [UInt8] {
        var out: [UInt8] = []; var o = 0
        while o + 188 <= ts.count {
            if (Int(ts[o + 1] & 0x1f) << 8 | Int(ts[o + 2])) == pid {
                let afc = (ts[o + 3] >> 4) & 3
                let start = o + 4 + (afc & 2 != 0 ? 1 + Int(ts[o + 4]) : 0)
                out += ts[start..<(o + 188)]
            }
            o += 188
        }
        return out
    }

    func build() -> (encrypted: [UInt8], clearVideo: [UInt8], clearAudio: [UInt8]) {
        // Vídeo: un NAL de tipo 1 de 400 bytes sin ceros (sin bytes de escape)
        var nal: [UInt8] = [0x41] + (1..<400).map { UInt8(($0 % 250) + 1) }
        let clearNal = nal
        encryptBlocks(&nal, at: [32, 192, 352])
        let clearVideo = pes(0xE0, [0, 0, 1] + clearNal)
        let encVideo = pes(0xE0, [0, 0, 1] + nal)
        // Audio: dos tramas ADTS de 60 bytes: cabecera (7) + 16 claros + 2 bloques cifrados + 5 de cola
        func frame(_ seed: UInt8) -> [UInt8] {
            let fl = 60
            var f: [UInt8] = [0xff, 0xf1, 0x50, UInt8(0x80 | ((fl >> 11) & 3)), UInt8((fl >> 3) & 0xff), UInt8(((fl & 7) << 5) | 0x1f), 0xfc]
            f += (0..<(fl - 7)).map { UInt8(truncatingIfNeeded: Int(seed) &+ $0 &* 3) }
            return f
        }
        var a1 = frame(10), a2 = frame(90)
        let clearAudio = pes(0xC0, a1 + a2)
        encryptBlocks(&a1, at: [23, 39]); encryptBlocks(&a2, at: [23, 39])
        let encAudio = pes(0xC0, a1 + a2)
        // PAT y PMT (con tipos 0xDB y 0xCF: «cifrado»). El CRC lo recalcula el descifrador.
        let pat: [UInt8] = [0x00, 0xB0, 13, 0, 1, 0xC1, 0, 0, 0, 1, 0xE0, UInt8(pmtPid), 0, 0, 0, 0]
        let pmt: [UInt8] = [0x02, 0xB0, 23, 0, 1, 0xC1, 0, 0, 0xE1, 0x00, 0xF0, 0,
                            0xDB, 0xE1, 0x00, 0xF0, 0, 0xCF, 0xE1, 0x01, 0xF0, 0, 0, 0, 0, 0]
        var ts: [UInt8] = []
        ts += packet(pid: 0, pusi: true, cc: 0, payload: section(pat))
        ts += packet(pid: pmtPid, pusi: true, cc: 0, payload: section(pmt))
        ts += packets(pid: videoPid, pes: encVideo)
        ts += packets(pid: audioPid, pes: encAudio)
        return (ts, clearVideo, clearAudio)
    }

    func testDescifraVideoYAudio() throws {
        let t = build()
        let out = try XCTUnwrap(TsSampleAes.decrypt(t.encrypted, key: key, iv: iv))
        XCTAssertEqual(out.count % 188, 0)
        XCTAssertEqual(extract(out, pid: videoPid).prefix(t.clearVideo.count), t.clearVideo[...], "vídeo igual al original")
        XCTAssertEqual(extract(out, pid: audioPid).prefix(t.clearAudio.count), t.clearAudio[...], "audio igual al original")
        // La PMT ya declara H.264 y AAC normales
        let pmtBytes = extract(out, pid: pmtPid)
        XCTAssertTrue(pmtBytes.contains(0x1b) && !pmtBytes.contains(0xdb) && pmtBytes.contains(0x0f))
    }

    func testRechazaLoQueNoEsTs() {
        XCTAssertNil(TsSampleAes.decrypt([UInt8](repeating: 1, count: 188), key: key, iv: iv))
        XCTAssertNil(TsSampleAes.decrypt([0x47, 0, 0], key: key, iv: iv))
    }
}

/// El reescritor deja pasar la clave de SAMPLE-AES en TS al relay (con el IV de la lista o el número de secuencia).
final class TsRewriteTests: XCTestCase {
    func testSegmentosTsLlevanClaveEIv() {
        let pl = "#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:5\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"key.bin\",IV=0x000102030405060708090a0b0c0d0e0f\n#EXTINF:4,\na.ts\n#EXTINF:4,\nb.ts\n"
        let out = HlsRewriter.rewrite(pl, base: URL(string: "https://h/p/l.m3u8")!, relay: "http://127.0.0.1:1/s")
        XCTAssertFalse(out.contains("#EXT-X-KEY"))
        XCTAssertEqual(out.components(separatedBy: "&v=000102030405060708090a0b0c0d0e0f").count - 1, 2)
        XCTAssertTrue(out.contains("/seg?u=") && out.contains("&k="))
        // Sin IV: número de secuencia (5 y 6)
        let sin = HlsRewriter.rewrite(pl.replacingOccurrences(of: ",IV=0x000102030405060708090a0b0c0d0e0f", with: ""), base: URL(string: "https://h/p/l.m3u8")!, relay: "http://127.0.0.1:1/s")
        XCTAssertTrue(sin.contains("&v=00000000000000000000000000000005") && sin.contains("&v=00000000000000000000000000000006"))
    }
}

/// Movistar: HLS con segmentos TS SAMPLE-AES y dirección FairPlay (skd://) que lleva KeyId e IV; la clave sale de la lista.
final class SkdTests: XCTestCase {
    let skd = "skd://eyJDb250ZW50SWQiOiI0NTIxIiwiS2V5SWQiOiI1NzIwYmIwNS0yNmI3LTQyZWYtODBhMC1kM2QwZDZlM2ZjZGQiLCJJViI6ImtsZkpheTlQaFZ5WitGRHZiSU9tRXc9PSJ9"

    func testSkdDaKidEIv() {
        let i = HlsRewriter.skdInfo(skd)
        XCTAssertEqual(i?.kid, "5720bb0526b742ef80a0d3d0d6e3fcdd")
        XCTAssertEqual(i?.iv, "9257c96b2f4f855c99f850ef6c83a613")
    }

    func testReescrituraConKid() {
        let pl = "#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:1\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"\(skd)\",KEYFORMAT=\"com.apple.streamingkeydelivery\",KEYFORMATVERSIONS=\"1\"\n#EXTINF:6,\ns1.ts\n"
        let out = HlsRewriter.rewrite(pl, base: URL(string: "https://h/p/l.m3u8")!, relay: "http://127.0.0.1:1/s")
        XCTAssertFalse(out.contains("#EXT-X-KEY"))
        XCTAssertTrue(out.contains("&kid=5720bb0526b742ef80a0d3d0d6e3fcdd&v=9257c96b2f4f855c99f850ef6c83a613"), out)
    }
}
